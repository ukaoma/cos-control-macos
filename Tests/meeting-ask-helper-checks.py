#!/usr/bin/env python3
"""V2 helper against a private loopback fixture. No real server, account, or credentials."""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
with tempfile.TemporaryDirectory(prefix='cos-ask-v2-', dir='/tmp') as tmp:
    home=pathlib.Path(tmp); (home/'.cos-glasses').mkdir()
    token='b'*64
    (home/'.cos-glasses/.env').write_text('COS_API_TOKEN='+token+'\n')
    status=200; body={'protocolVersion':2,'serverInstanceId':'fixture','selected':{'engine':'claude','model':'haiku'},'models':[]}; requests=[]; health_requests=[]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def answer(self):
            if self.path == '/api/health':
                health_requests.append(self.path)
                raw=b'{\"ok\":true}'; self.send_response(200); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw); return
            assert self.headers.get('X-COS-Token')==token
            data=self.rfile.read(int(self.headers.get('Content-Length','0')))
            requests.append((self.command,self.path,json.loads(data) if data else None))
            raw=json.dumps(body).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
        do_GET=do_POST=do_PUT=answer
    server=HTTPServer(('127.0.0.1',0),Handler); threading.Thread(target=server.serve_forever,daemon=True).start()
    env=dict(os.environ,COS_CONTROL_TEST_HOME=tmp,COS_CONTROL_TEST_API_PORT=str(server.server_port))
    def run(operation,payload=None):
        result=subprocess.run([sys.argv[1],'meeting-ask'],input=json.dumps({'operation':operation,'payload':payload or {}}).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=15)
        assert not result.stderr,result.stderr
        assert token not in result.stdout.decode()
        return json.loads(result.stdout)
    try:
        identity=run('identity'); assert identity['ok'] and len(identity['details']['pairingContext'])==64 and not requests and not health_requests
        live_port=env['COS_CONTROL_TEST_API_PORT']; env['COS_CONTROL_TEST_API_PORT']='1'
        offline_identity=run('identity'); assert offline_identity==identity
        env['COS_CONTROL_TEST_API_PORT']=live_port
        config=run('config'); assert config['ok'] and config['details']['pairingContext']==identity['details']['pairingContext']
        assert requests[-1][:2]==('GET','/api/meeting-ask/config')
        run('configure',{'engine':'codex','model':'balanced'}); assert requests[-1][0]=='PUT'
        rid='12345678-1234-4234-8234-123456789012'
        run('submit',{'requestId':rid,'question':'PRIVATE fixture words'}); assert requests[-1]==('POST','/api/meeting-ask/requests',{'requestId':rid,'question':'PRIVATE fixture words'})
        run('status',{'requestId':rid}); assert requests[-1][:2]==('GET','/api/meeting-ask/requests/'+rid)
        run('cancel',{'requestId':rid,'serverInstanceId':'fixture'}); assert requests[-1][0]=='POST'
        run('history',{'sessionId':'meeting_fixture','serverInstanceId':'fixture'}); assert 'sessionId=meeting%5Ffixture' in requests[-1][1]
        run('files',{'sessionId':'meeting_fixture','files':[]}); assert requests[-1][:2]==('PUT','/api/meeting-ask/files')
        prior=len(requests); assert not run('status',{'requestId':'../../etc/passwd'})['ok']; assert not run('delete')['ok']; assert len(requests)==prior
        status=503; body={'error':'SECRET stderr and transcript'}
        failure=run('config'); assert not failure['ok'] and 'SECRET' not in json.dumps(failure)
        status=404; assert 'Update' in run('config')['message']
        print('PASS Meeting Ask v2 helper: local identity, auth, fixed routes, stdin, cancellation, history, files, path refusal, redacted failures')
    finally: server.shutdown()
