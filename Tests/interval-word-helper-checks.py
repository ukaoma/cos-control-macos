#!/usr/bin/env python3
"""Compiled helper against authenticated loopback only; no live server or desktop UI."""
import copy,json,os,pathlib,subprocess,sys,tempfile,threading,urllib.parse
from http.server import BaseHTTPRequestHandler,HTTPServer
checks=0
def check(ok,note):
 global checks
 checks+=1
 assert ok,note
with tempfile.TemporaryDirectory(prefix='cos-interval-word-helper-',dir='/tmp') as tmp:
 home=pathlib.Path(tmp);(home/'.cos-glasses').mkdir();token='fixture-'+('b'*64);(home/'.cos-glasses/.env').write_text('COS_API_TOKEN='+token+'\n')
 calls=[];status=200;answer={'preview':{'fields':1,'enrollmentAllowed':False}}
 class Handler(BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def do_GET(self):
   if self.path!='/api/health':calls.append((self.path,None))
   self.send_response(200);self.end_headers();self.wfile.write(b'{"ok":true}')
  def do_POST(self):
   check(self.headers.get('X-COS-Token')==token,'Private authentication')
   payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))));calls.append((self.path,payload));self.send_response(status);self.end_headers();self.wfile.write(json.dumps(answer).encode())
 server=HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
 env={**os.environ,'HOME':tmp,'COS_CONTROL_TEST_HOME':tmp,'COS_CONTROL_TEST_API_PORT':str(server.server_port),'COS_LIVE_CUES_V2':'0','COS_SPEAKER_SHADOW':'0','COS_MAC_SPEAKER_LIVE':'0','COS_MAC_ACOUSTIC_VOICES':'0'}
 sid='mac_11111111-1111-4111-8111-111111111111'
 base={'sessionId':sid,'recordId':'fixture-record','expectedRevision':'a'*64,'identityId':'fluid256_fixture','scopeSHA256':'b'*64,'memberIds':['c'*64,'d'*64],'to':'Fixture Person','dryRun':True}
 def run(command,body,args=()):
  raw=body if isinstance(body,str) else json.dumps(body)
  p=subprocess.run([sys.argv[1],command,*args],input=raw.encode(),capture_output=True,env=env,timeout=15)
  check(not p.stderr,'No stderr');check(token.encode() not in p.stdout,'No token disclosure');return json.loads(p.stdout)
 try:
  r=run('meeting-interval-group-preview',base);check(r['details']['state']=='preview','Preview stays unconfirmed')
  path,payload=calls[-1];check(urllib.parse.unquote(path)==f'/api/meeting/{sid}/speaker-interval-groups/fluid256_fixture/relabel','Fixed exact-word endpoint')
  check(payload=={k:v for k,v in base.items() if k not in ('sessionId','identityId')},'No raw expansion or enrollment fields')
  confirmed={k:v for k,v in base.items() if k!='dryRun'}|{'confirm':True};answer={'ok':True,'confirmed':True,'enrollmentAllowed':False}
  check(run('meeting-interval-group-relabel',confirmed)['details']['state']=='applied','Explicit save')
  undo={'sessionId':sid,'recordId':'fixture-record','expectedRevision':'a'*64,'actionId':'action_1','annotationRevision':2,'annotationSHA256':'e'*64,'confirm':True}
  run('meeting-interval-group-undo',undo);check(calls[-1][0].endswith('/speaker-interval-groups/undo') and calls[-1][1]['annotationRevision']==2,'Exact guarded Undo')
  original={'sessionId':sid,'recordId':'fixture-record','expectedRevision':'a'*64,'confirm':True}
  run('meeting-interval-group-original',original);check(calls[-1][0].endswith('/speaker-interval-groups/original') and calls[-1][1]=={k:v for k,v in original.items() if k!='sessionId'},'Original view request is explicit and revision guarded')
  run('meeting-interval-group-recover',{'sessionId':sid,'recordId':'fixture-record','confirm':True});check(calls[-1][0].endswith('/speaker-interval-groups/recover') and calls[-1][1]=={'recordId':'fixture-record','confirm':True},'Recovery only confirms saved journal; never resubmits selection')
  run('meeting-interval-groups',{'sessionId':sid,'recordId':'fixture-record'});check(urllib.parse.urlparse(calls[-1][0]).path.endswith('/speaker-interval-groups') and urllib.parse.parse_qs(urllib.parse.urlparse(calls[-1][0]).query)=={'recordId':['fixture-record']},'Fixed GET scope read')
  malformed=[]
  for key,val in [('force',True),('profile','person'),('assignVoiceProfile',True),('rawChunkIndices',[4]),('file','/tmp/x'),('confirm',True),('memberIds',[]),('memberIds',['c'*64,'c'*64]),('memberIds',['raw-4']),('memberIds',['c'*64]*20001),('to','Ext'),('to','Voice 2'),('to','bad\nname'),('dryRun',1),('expectedRevision','a'*63),('identityId','../bad')]:
   b=copy.deepcopy(base);b[key]=val;malformed.append(('meeting-interval-group-preview',b,()))
  malformed += [('meeting-interval-group-recover',{'sessionId':sid,'recordId':'fixture-record','confirm':1},()),('meeting-interval-group-recover',{'sessionId':sid,'recordId':'fixture-record','confirm':True,'memberIds':['c'*64]},())]
  malformed += [('meeting-interval-group-preview',base,('--force',)),('meeting-interval-group-preview','x'*2097153,()),('meeting-interval-group-relabel',base,())]
  for key,val in [('annotationRevision',True),('annotationRevision',0),('annotationRevision',1.5),('annotationSHA256','bad'),('actionId','../x'),('force',True)]:
   b=copy.deepcopy(undo);b[key]=val;malformed.append(('meeting-interval-group-undo',b,()))
  for key,value in [('confirm',1),('expectedRevision','bad'),('force',True),('memberIds',['c'*64])]:
   b=copy.deepcopy(original);b[key]=value;malformed.append(('meeting-interval-group-original',b,()))
  for command,b,args in malformed:
   before=len(calls);r=run(command,b,args);check(not r['ok'] and len(calls)==before,'Invalid/profile/force arguments never reach naming endpoint')
  for code in (409,422,404):
   status=code;answer={'reason':'stale_revision','message':'Refresh words'};r=run('meeting-interval-group-preview',base);check(r['details']['state']!='applied','Stale or missing endpoint never applies')
  print(f'PASS interval word compiled helper: {checks} bounded stdin, exact payload, stale and unsafe-option checks')
 finally:server.shutdown();server.server_close()
