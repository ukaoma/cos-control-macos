#!/usr/bin/env python3
"""Compiled helper, private fixture home, authenticated ephemeral loopback server. Never real credentials."""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
with tempfile.TemporaryDirectory(prefix='cos-ask-helper-', dir='/tmp') as tmp:
    home=pathlib.Path(tmp); (home/'.cos-glasses').mkdir()
    token='b'*64
    (home/'.cos-glasses/.env').write_text('COS_API_TOKEN='+token+'\n')
    status=200; body={'answer':'Maya will send the draft. [T1]','sources':[],'notices':[],'model':'haiku','throughMs':1000}; received=[]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def send(self,code,value):
            data=json.dumps(value).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_GET(self): self.send(200,{'ok':True})
        def do_POST(self):
            assert self.path=='/api/meetings/live-ask'
            assert self.headers.get('X-COS-Token')==token
            received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            self.send(status,body)
    server=HTTPServer(('127.0.0.1',0),Handler); threading.Thread(target=server.serve_forever,daemon=True).start()
    env=dict(os.environ,COS_CONTROL_TEST_HOME=tmp,COS_CONTROL_TEST_API_PORT=str(server.server_port))
    request={'sessionId':'meeting_123_fixture','action':'summary','question':'Summarize so far','elapsedMs':1000,'turns':[{'id':1,'speaker':'Maya','elapsedMs':0,'text':'Fixture speech.'}]}
    def run(value):
        result=subprocess.run([sys.argv[1],'live-cos-ask'],input=json.dumps(value).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=15)
        assert not result.stderr, result.stderr
        assert token not in result.stdout.decode()
        return json.loads(result.stdout)
    try:
        good=run(request); assert good['ok'] and good['details']['answer']==body['answer']; assert received==[request]
        for status,fragment in [(404,'Update'),(401,'Reconnect'),(429,'Another answer'),(503,'Haiku')]:
            body={'error':'SECRET provider transcript or credential'}; failure=run(request)
            assert not failure['ok'] and fragment in failure['message'] and 'SECRET' not in json.dumps(failure)
        status=422; body={'error':'no_recent_words'}; assert 'no recent words' in run(request)['message']
        before=len(received); assert not run({'sessionId':'../invalid'})['ok']; assert len(received)==before
        print('PASS Live COS Ask helper: authenticated stdin transport, success, older server, unauthorized, busy, provider redaction, empty window, invalid input')
    finally: server.shutdown()
