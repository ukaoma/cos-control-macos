#!/usr/bin/env python3
"""Real helper transport against disposable loopback; no production/provider commands."""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
root=pathlib.Path(tempfile.mkdtemp(prefix='cos-hardening-helper-',dir='/tmp'))
(root/'.cos-glasses').mkdir();(root/'.cos-glasses/.env').write_text('COS_API_TOKEN='+'a'*64+'\n')
calls=[];reason='meeting_finalizing'
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        calls.append((self.path,None));self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'sessionId':'meeting_fixture','recordId':'ops:personal:2026-10:merged.md','sourceRevision':'b'*64}).encode())
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));calls.append((self.path,body))
        self.send_response(409);self.end_headers();self.wfile.write(json.dumps({'reason':reason,'error':'Explicit recovery reason','retryable':True}).encode())
server=HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
env=dict(os.environ,COS_CONTROL_TEST_HOME=str(root),COS_CONTROL_TEST_API_PORT=str(server.server_port))
def run(*args):
    out=subprocess.run([sys.argv[1],*args],env=env,capture_output=True,timeout=20)
    return json.loads(out.stdout)
try:
    for reason,expected in [('meeting_finalizing','meeting_finalizing'),('record_source_mismatch','record_source_mismatch'),('direct_library_read_only','direct_library_read_only'),('correction_pending','pending_correction'),('unknown_conflict','declined'),(None,'declined')]:
        res=run('meeting-relabel','--session','meeting_fixture','--from','Speaker 1','--to','Miles','--record-id','ops:personal:2026-10:merged.md','--expected-revision','b'*64)
        assert res['details']['state']==expected,res
        assert calls[-1][1]['expectedRevision']=='b'*64
        assert calls[-1][1]['recordId']=='ops:personal:2026-10:merged.md'
        assert res['details']['result']['error']=='Explicit recovery reason'
    for command,route in [('meeting-speakers','speakers'),('meeting-content','content')]:
        assert run(command,'--session','meeting_fixture','--record-id','ops:personal:2026-10:merged.md')['ok']
        assert calls[-1][0]=='/api/meeting/meeting_fixture/'+route+'?recordId=ops%3Apersonal%3A2026%2D10%3Amerged%2Emd',calls[-1]
    print('PASS: selected record and source revision cross compiled helper; six 409 recovery cases, including a missing reason')
finally:
    server.shutdown();shutil.rmtree(root)
