#!/usr/bin/env python3
"""Compiled policy helper against isolated authenticated loopback; no live writes."""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
root=pathlib.Path(tempfile.mkdtemp(prefix='cos-policy-helper-',dir='/tmp'))
(root/'.cos-glasses').mkdir(); token='c'*64
(root/'.cos-glasses/.env').write_text('COS_API_TOKEN='+token+'\n')
calls=[]; status=200; answer={'mode':'standard','revision':'unset'}
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def respond(self,method):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length']))) if method=='POST' else None
  assert self.headers.get('X-COS-Token')==token
  calls.append((method,self.path,body)); self.send_response(status);self.end_headers();self.wfile.write(json.dumps(answer).encode())
 def do_GET(self):
  if self.path=='/api/health':
   self.send_response(200);self.end_headers();self.wfile.write(b'{"ok":true}');return
  self.respond('GET')
 def do_POST(self): self.respond('POST')
server=HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
env=dict(os.environ,COS_CONTROL_TEST_HOME=str(root),COS_CONTROL_TEST_API_PORT=str(server.server_port))
def run(*args):
 p=subprocess.run([sys.argv[1],'meeting-speaker-policy','--session','meeting_fixture',*args],env=env,capture_output=True,timeout=20)
 return json.loads(p.stdout)
try:
 result=run(); assert result['ok'] and result['details']==answer
 assert calls[-1]==('GET','/api/meeting/meeting_fixture/speaker-policy',None)
 answer={'mode':'anonymous','revision':'unreadable','error':'Invalid speaker policy'}
 result=run();assert result['ok'] and result['details']==answer, 'Fail-closed corruption must reach the UI intact'
 answer={'mode':'high-confidence','revision':'d'*64}
 result=run('--mode','high-confidence','--policy-revision','unreadable','--record-id','ops:quilt:2026-10:m.md','--expected-revision','e'*64)
 assert result['ok'] and result['details']==answer
 assert calls[-1]==('POST','/api/meeting/meeting_fixture/speaker-policy',{'mode':'high-confidence','expectedPolicyRevision':'unreadable','recordId':'ops:quilt:2026-10:m.md','expectedRevision':'e'*64})
 count=len(calls); assert not run('--mode','bogus','--policy-revision','unset')['ok']; assert not run('--mode','anonymous')['ok'];assert len(calls)==count
 for status in [404,409]:
  answer={'error':'Selected meeting changed; reopen it'}
  result=run('--mode','anonymous','--policy-revision','unset');assert not result['ok'] and 'Selected meeting changed' in result['message']
 status=403;answer={'error':'SECRET'};result=run();assert not result['ok'] and 'Unauthorized' in result['message'] and 'SECRET' not in json.dumps(result)
 print('PASS: compiled policy helper GET, guarded POST, corruption, invalid input, stale/older server and auth refusal')
finally:
 server.shutdown();shutil.rmtree(root)
