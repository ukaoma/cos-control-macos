#!/usr/bin/env python3
"""Actual compiled helper; private auth and ephemeral loopback, never the live server."""
import json,os,pathlib,subprocess,sys,tempfile,threading,urllib.parse
from http.server import BaseHTTPRequestHandler,HTTPServer
checks=0
def check(ok,note):
 global checks
 checks+=1
 assert ok,note
with tempfile.TemporaryDirectory(prefix='cos-speaker-group-helper-',dir='/tmp') as tmp:
 home=pathlib.Path(tmp);(home/'.cos-glasses').mkdir();token='fixture-'+('b'*64);(home/'.cos-glasses/.env').write_text('COS_API_TOKEN='+token+'\n')
 calls=[];status=200;answer={'preview':{'fields':2,'enrollmentAllowed':False}}
 class Handler(BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def do_GET(self):
   check(self.path=='/api/health','Only local health discovery permitted');self.send_response(200);self.end_headers();self.wfile.write(b'{"ok":true}')
  def do_POST(self):
   check(self.headers.get('X-COS-Token')==token,'Exact private authentication')
   payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))));calls.append((self.path,payload));self.send_response(status);self.end_headers();self.wfile.write(json.dumps(answer).encode())
 server=HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 env={**os.environ,'HOME':tmp,'COS_CONTROL_TEST_HOME':tmp,'COS_CONTROL_TEST_API_PORT':str(server.server_port),'COS_LIVE_CUES_V2':'0','COS_SPEAKER_SHADOW':'0','COS_MAC_SPEAKER_LIVE':'0','COS_MAC_ACOUSTIC_VOICES':'0'}
 sid='mac_11111111-1111-4111-8111-111111111111';base=['meeting-group-relabel','--session',sid,'--record-id','ops:quilt:2026-10:fixture.md','--expected-revision','a'*64,'--identity','fluid256_fixture','--scope-sha256','b'*64,'--raw-chunks','9,4','--to','Fixture Person']
 def run(args):
  p=subprocess.run([sys.argv[1],*args],capture_output=True,env=env,timeout=15);check(not p.stderr,'No stderr/private data');check(token.encode() not in p.stdout,'Token never disclosed');return json.loads(p.stdout)
 def replace(key,value):
  a=list(base);a[a.index(key)+1]=value;return a
 try:
  r=run(base);check(r['ok'] and r['details']['state']=='preview','Preview response retained');path,payload=calls[-1];check(urllib.parse.unquote(path)==f'/api/meeting/{sid}/speaker-groups/fluid256_fixture/relabel','Exact fixed scoped endpoint');check(payload=={'recordId':'ops:quilt:2026-10:fixture.md','expectedRevision':'a'*64,'scopeSHA256':'b'*64,'rawChunkIndices':[4,9],'to':'Fixture Person','dryRun':True},'Exact preview payload; no enrollment/force')
  answer={'confirmed':True,'enrollmentAllowed':False};r=run(base+['--confirm']);check(r['ok'] and r['details']['state']=='applied','Explicit confirmation applies');check(calls[-1][1]=={k:v for k,v in payload.items() if k!='dryRun'}|{'confirm':True},'Confirmation only swaps dryRun flag')
  malformed=[base+['--force'],base+['--assign-voice-profile'],base+['--profile','someone'],base+['--confirm','--confirm'],base+['--to','Other'],base+['--mystery','x']]
  malformed += [replace('--raw-chunks',x) for x in ['', '4,4','04','-1','6000','4,','4,,9','4.0','2e0','4 9']]
  malformed += [replace('--to',x) for x in ['A','Ext','Unknown','MU','Unidentified','Voice 9',' Leading','Trailing ','bad\nname','x'*201]]
  malformed += [replace('--expected-revision',x) for x in ['a'*63,'A'*64,'g'*64]]
  malformed += [replace('--identity',x) for x in ['../../bad','x/y','x'*129]]
  malformed += [replace('--session','meeting_g2_fixture'),replace('--scope-sha256','bad')]
  for args in malformed:
   before=len(calls);result=run(args);check(not result['ok'],'Malformed/force/profile request refused');check(len(calls)==before,'Rejected arguments never reach naming endpoint')
  for code,state in [(409,'declined'),(422,'declined'),(404,'route_missing')]:
   status=code;answer={'reason':'stale_group','message':'Refresh selected group'};result=run(base);check(result['ok'] and result['details']['state']==state,f'HTTP{code} cannot become applied')
  status=403;answer={'error':'SECRET fixture private failure'};result=run(base);check(not result['ok'] and 'SECRET' not in json.dumps(result),'Unauthorized redacted and refused')
  print(f'PASS speaker group compiled helper: {checks} checks; authenticated preview/confirm, exact payload, stale, unknown/force/profile refusal')
 finally:server.shutdown();server.server_close()
