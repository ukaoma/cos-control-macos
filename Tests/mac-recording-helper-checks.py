#!/usr/bin/env python3
"""Bounded manual-Mac recording bridge against an authenticated loopback stand-in only.
Usage: python3 Tests/mac-recording-helper-checks.py <compiled helper>
No native capture, live service, TCC prompt, or real audio is used.
"""
import json, os, pathlib, struct, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
work = pathlib.Path(tempfile.mkdtemp(prefix='cos-mac-recording-', dir='/tmp'))
home = work / 'home'
(home / '.cos-glasses').mkdir(parents=True, mode=0o700)
token = 'b' * 64
(home / '.cos-glasses/.env').write_text('COS_API_TOKEN=' + token + '\n')
(home / '.cos-glasses/.env').chmod(0o600)
capture = 'mac_12345678-1234-1234-1234-123456789abc'
spool = home / 'cos-data/mac-recordings' / capture
spool.mkdir(parents=True, mode=0o700)
wav = b'RIFF' + struct.pack('<I', 38) + b'WAVEfmt ' + struct.pack('<IHHIIHH',16,1,1,16000,32000,2,16) + b'data' + struct.pack('<I',2) + b'\x00\x00'
path = spool / '000000.wav'
path.write_bytes(wav)
path.chmod(0o600)
seen = []
answer = {'status': 200, 'body': {'serverInstanceId': 'fixture-server', 'available': True, 'sourceType': 'mac_system_audio'}}
checks = 0

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def respond(self):
        if self.path == '/api/health':
            raw=b'{"ok":true}'; self.send_response(200); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw); return
        data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        seen.append((self.command, self.path, {key.lower():value for key,value in self.headers.items()}, data))
        authenticated = self.headers.get('X-COS-Token') == token
        raw = json.dumps(answer['body'] if authenticated else {'error':'unauthorized'}).encode()
        self.send_response(answer['status'] if authenticated else 401)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers(); self.wfile.write(raw)

server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))
def check(value, label):
    global checks
    assert value, label
    checks += 1

def run(operation, payload=None, raw=None):
    request = raw if raw is not None else json.dumps({'operation':operation,'payload':payload or {}})
    process = subprocess.run([helper, 'mac-recording'], input=request, text=True, capture_output=True, env=env, timeout=15)
    check(not process.stderr and process.returncode == 0, 'bounded helper emits JSON without stderr')
    check(token not in process.stdout, 'token never emitted')
    return json.loads(process.stdout)

def refused(payload, label, operation='chunk'):
    before = len(seen)
    result = run(operation, payload)
    check(not result['ok'] and len(seen) == before, label)

base = {'captureId':capture,'serverInstanceId':'fixture-server'}
chunk = dict(base, path=str(path), chunkIndex=0, elapsed=1)
try:
    check(run('capabilities')['ok'], 'capability request works without paired glasses')
    check(seen[-1][1] == '/api/mac-recording/capabilities', 'capabilities route fixed')
    check(run('start', dict(base,startTime=1792026000000))['ok'], 'register capture')
    request = seen[-1]
    check(request[2].get('x-cos-server-instance') == 'fixture-server', 'start pins server')
    check(json.loads(request[3]) == {'captureId':capture,'startTime':1792026000000,'sourceType':'mac_system_audio'}, 'source type immutable')
    check(run('start', dict(base,startTime=1792026000000.875))['ok'], 'native fractional clock admitted by bridge')
    check(json.loads(seen[-1][3])['startTime'] == 1792026000000, 'bridge canonicalizes native fractional clock to integer milliseconds')
    refused(dict(base,startTime=0.5), 'sub-millisecond start refused','start')
    refused(dict(base,startTime=1e20), 'unsafe integer clock refused','start')

    check(run('chunk', chunk)['ok'], 'read confined canonical WAV')
    request = seen[-1]
    check(request[1].startswith('/api/mac-recording/'+capture+'/chunks?chunkIndex=0&elapsed=1'), 'chunk route and sequence')
    check(request[3] == wav and request[2].get('content-type') == 'audio/wav', 'raw canonical WAV not JSON or base64')
    check(run('chunk', dict(chunk,path=str(path.resolve())))['ok'], 'signed host canonical spool path shares the isolated helper home')
    check(run('save', dict(base,title='Fixture Mac recording',expectedChunkCount=1))['ok'], 'save uses canonical route')
    check(seen[-1][1] == '/api/meeting/save' and json.loads(seen[-1][3])['sessionId'] == capture, 'save exact capture identity')
    check(json.loads(seen[-1][3])['expectedChunkCount']==1,'save binds expected chunk count')
    check(run('status', base)['ok'] and seen[-1][1].startswith('/api/meeting/sessions/'+capture+'/status'), 'status route exact capture')
    refused(dict(chunk,serverInstanceId=''), 'missing pin refused')
    refused(dict(chunk,captureId='../outside'), 'traversal capture refused')
    refused(dict(chunk,sessionId='other'), 'conflicting session refused')
    refused(dict(chunk,chunkIndex=True), 'bool index refused')
    refused(dict(chunk,chunkIndex=0.5), 'fractional index refused')
    refused(dict(chunk,elapsed=-1), 'negative elapsed refused')
    refused(dict(chunk,path=str(path.parent/'..'/path.name)), 'unstandardized path refused')
    outside = work/'outside.wav'; outside.write_bytes(wav)
    refused(dict(chunk,path=str(outside)), 'external path refused')
    link = spool/'link.wav'; link.symlink_to(outside)
    refused(dict(chunk,path=str(link)), 'symlink file refused')
    hard = spool/'hard.wav'; os.link(outside,hard)
    refused(dict(chunk,path=str(hard)), 'hardlink refused')
    bad = spool/'bad.wav'; bad.write_bytes(b'not WAV data'*10)
    refused(dict(chunk,path=str(bad)), 'malformed WAV refused')
    huge = spool/'huge.wav'
    with huge.open('wb') as stream: stream.truncate(960045)
    refused(dict(chunk,path=str(huge)), 'oversized WAV refused')
    fake_capture='mac_22345678-1234-1234-1234-123456789abc'
    (spool.parent/fake_capture).symlink_to(spool, target_is_directory=True)
    refused(dict(chunk,captureId=fake_capture,path=str(spool.parent/fake_capture/path.name)), 'symlink capture directory refused')
    refused(dict(base,expectedChunkCount=True),'bool count refused','save')
    refused(dict(base,expectedChunkCount=1202),'oversized count refused','save')
    refused(dict(base,startTime=True), 'bool start refused','start')
    answer.update(status=400,body={'reason':'invalid_mac_capture'})
    result=run('start',dict(base,startTime=1792026000000))
    check(not result['ok'] and 'No audio was captured' in result['message'] and result['details']['reason']=='invalid_mac_capture','start rejection does not falsely claim retained audio')
    answer.update(status=200,body={'serverInstanceId':'fixture-server','available':True,'sourceType':'mac_system_audio'})

    before=len(seen)
    result=run('capabilities',raw='x'*16385)
    check(not result['ok'] and len(seen)==before,'oversized stdin refused before network')
    answer.update(status=409,body={'reason':'capture_conflict','error':'sensitive private prompt '+token})
    result=run('start',dict(base,startTime=1792026000000))
    check(not result['ok'] and result['details']['httpStatus']==409 and result['details']['reason']=='capture_conflict','safe conflict retained')
    check('sensitive private prompt' not in json.dumps(result),'raw server errors hidden')
    print('mac-recording helper checks: %d passed'%checks)
finally:
    server.shutdown()
    import shutil
    shutil.rmtree(work)
