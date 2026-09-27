#!/usr/bin/env python3
"""Exercise the compiled helper with loopback fixtures; never target live service."""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
helper=sys.argv[1]
root=pathlib.Path(tempfile.mkdtemp(prefix='cos-work-review-helper-',dir='/tmp'))
token='a'*64
(root/'.cos-glasses').mkdir(mode=0o700)
(root/'.cos-glasses/.env').write_text('COS_API_TOKEN='+token+'\n');(root/'.cos-glasses/.env').chmod(0o600)
(root/'candidate-token').write_text(token);(root/'candidate-token').chmod(0o600)
calls=[]
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        assert self.headers.get('X-COS-Token')==token
        calls.append((self.command,self.path,None))
        if self.path=='/api/tasks':
            rows=[{'id':str(i),'domain':'personal','title':'short','text':'Full task '+str(i),'source':'savedmeeting','doneWhen':'Finish line','checked':i==64,'agentState':'done' if i==63 else '', 'stage':'review'} for i in range(65)]
            data={'tasks':rows}
        else:data={'schemaVersion':1,'capabilities':{'manualReview':True},'reviews':[]}
        self.send_response(200);self.end_headers();self.wfile.write(json.dumps(data).encode())
    def do_POST(self):
        assert self.headers.get('X-COS-Token')==token
        raw=self.rfile.read(int(self.headers['Content-Length'])); data=json.loads(raw);calls.append((self.command,self.path,data))
        self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'review':{'id':'fixture','source':{},'echo':data}}).encode())
server=HTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
base=dict(os.environ,COS_CONTROL_TEST_HOME=str(root),COS_CONTROL_TEST_API_PORT=str(server.server_port))
def run(args,env,data=None):
    result=subprocess.run([helper,*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=20)
    return json.loads(result.stdout)
try:
    board=run(['work-tasks'],base)['details']
    assert len(board['tasks'])==65 and board['complete']
    assert board['tasks'][64]['checked'] and board['tasks'][64]['text']=='Full task 64'
    assert board['tasks'][63]['agentState']=='done' and not board['tasks'][63]['checked']
    candidate=dict(os.environ,COS_WORK_CONNECTED_TEST='1',COS_WORK_REVIEW_CANDIDATE_PORT=str(server.server_port),COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(root/'candidate-token'))
    candidate.pop('COS_CONTROL_TEST_HOME',None)
    assert run(['work-reviews'],candidate)['ok']
    payload=json.dumps({'meeting':{'domain':'personal','month':'2026-09','filename':'QA résumé.md','recordId':'split:one'},'model':'ollama'}).encode()
    assert run(['work-review'],candidate,payload)['ok'] and calls[-1][2]['meeting']['recordId']=='split:one'
    before=len(calls)
    (root/'candidate-token').chmod(0o644)
    assert not run(['work-reviews'],candidate)['ok'] and len(calls)==before
    (root/'candidate-token').chmod(0o600)
    assert not run(['work-review'],candidate,b' '*16385)['ok'] and len(calls)==before
    bad=dict(candidate,COS_WORK_REVIEW_CANDIDATE_PORT='3141')
    assert not run(['work-reviews'],bad)['ok'] and len(calls)==before
    link=root/'linked-token';link.symlink_to(root/'candidate-token')
    assert not run(['work-reviews'],dict(candidate,COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE=str(link)))['ok'] and len(calls)==before
    print('PASS compiled helper: complete65-row task board, full context, task/agent states, exact review descriptor, bounded input, private token, no production override')
finally:
    server.shutdown()
    import shutil;shutil.rmtree(root)
