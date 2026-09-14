"""Executable helper contract against an isolated HTTP server and home, never production."""
import http.server, json, os, pathlib, subprocess, sys, tempfile, threading
from contextlib import contextmanager

helper = sys.argv[1]
state = {'caps': False, 'status': 200, 'requests': [], 'kind': 'preview', 'override': None}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        state['requests'].append(('GET', self.path, None))
        if self.path.endswith('/batches'):
            body = {'batches':[{'batchId':'batch-1','speaker':'Brigitta Pólya','status':'interrupted','undoHandle':'batch-1'}]}
        else:
            body = {'groups':[], 'loose':[], 'speakerModel':True}
            if state['caps']: body['namingCapabilities'] = {'version':1, 'preview':True, 'apply':True, 'undo':True}
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        state['requests'].append(('POST', self.path, data))
        body = {'success':state['status']==200, 'kind':state['kind'], 'speaker':'Brigitta Pólya', 'previewHash':'a'*64,
                'batchId':'batch-1', 'undoHandle':'batch-1', 'deleted':239,
                'meetings':[{'sessionId':'meeting_1','status':'failed','error':'copy refused','copies':[{'copy':'operations','status':'failed'}],
                             'playback':[{'sessionId':'meeting_1','chunkIndex':7,'position':3}]}]}
        if state['override'] is not None: body = state['override']
        self.send_response(state['status']); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='cos-held-wire-',dir='/tmp') as home:
    config=pathlib.Path(home)/'.cos-glasses'; config.mkdir(mode=0o700)
    token=config/'.env'; token.write_text('COS_API_TOKEN=isolated-test-token-never-production\n'); token.chmod(0o600)
    env={**os.environ,'COS_CONTROL_TEST_HOME':home,'COS_CONTROL_TEST_API_PORT':str(server.server_port)}
    members=json.dumps([{'sessionId':'meeting_1','chunkIndex':7}])
    def run(*args):
        result=subprocess.run([helper,*args],env=env,capture_output=True,text=True,timeout=15)
        try: return json.loads(result.stdout)
        except Exception: raise AssertionError(result.stdout+result.stderr)
    naming=['--name','Brigitta Pólya','--members',members]
    old=run('voice-held-preview',*naming)
    assert old['ok'] is False and '6.46.0' in old['message']
    assert not any(x[0]=='POST' for x in state['requests']), 'old server must never receive preview POST'
    state['caps']=True
    preview=run('voice-held-preview',*naming,'--confirm')
    assert preview['details']['previewHash']=='a'*64 and preview['details']['meetings'][0]['playback'][0]['chunkIndex']==7
    assert 'confirm' not in state['requests'][-1][2], 'preview must omit confirm even if caller passed it'
    before=len(state['requests']); malformed=run('voice-held-apply',*naming,'--confirm')
    assert malformed['ok'] is False and len(state['requests'])==before, 'missing hash fails before network'
    for status in (400,409,422,503,200):
        state['status']=status; state['kind']='applied'
        result=run('voice-held-apply',*naming,'--preview-hash','a'*64,'--confirm','--owner-ack','--listened')
        assert result['ok'] is True and result['details']['httpStatus']==status
        assert result['details']['meetings'][0]['copies'][0]['status']=='failed'
        assert result['details']['undoHandle']=='batch-1' and result['details']['deleted']==239
        assert state['requests'][-1][2]['ownerAck'] is True and state['requests'][-1][2]['listened'] is True
    # Match the route's real error envelopes: no kind/hash on refusal.
    for status, reason, message in ((404,'no_samples','None of those samples are held any more.'),
                                    (409,'preview_expired','The preview expired. Preview again.'),
                                    (503,'speaker_model_unavailable','The speaker model is not loaded. Nothing was changed.')):
        state['status']=status
        state['override']={'success':False,'error':message,'reason':reason,
                           'meetings':[{'sessionId':'meeting_1','status':'blocked','error':message}],
                           'missing':[{'sessionId':'meeting_1','chunkIndex':7}], 'notReady':[]}
        refusal=run('voice-held-apply',*naming,'--preview-hash','a'*64,'--confirm')
        assert refusal['message']==message and refusal['details']['httpStatus']==status and refusal['details']['state']=='refused'
        assert refusal['details']['reason']==reason and 'previewHash' not in refusal['details']
        assert refusal['details']['missing'][0]['chunkIndex']==7
    state['status']=200
    state['override']={'success':True,'kind':'applied','status':'partial','partial':True,'batchId':'batch-1','undoHandle':'batch-1',
                       'enrolled':1,'profileEmbeddings':40,'members':[{'sessionId':'meeting_1','chunkIndex':7,'status':'no_transcript_position','enrollmentStatus':'enrolled','labelStatus':'no_transcript_position','audioStatus':'retained','position':None}],'deleted':0,'meetings':[{'sessionId':'meeting_1','status':'failed','copies':[{'copy':'local','correctionRevision':0}],
                       'receipts':[{'copy':'local','status':'applied'},{'copy':'operations','status':'failed','error':'read-only'}]}]}
    partial=run('voice-held-apply',*naming,'--preview-hash','a'*64,'--confirm')
    assert partial['details']['profileEmbeddings']==40 and partial['details']['members'][0]['enrollmentStatus']=='enrolled'
    assert partial['details']['partial'] is True and partial['details']['enrolled']==1 and partial['details']['deleted']==0
    assert partial['details']['meetings'][0]['receipts'][1]['error']=='read-only'
    state['override']=None
    state['kind']='undone'
    undone=run('voice-held-undo','--batch-id','batch-1','--confirm')
    assert undone['details']['kind']=='undone' and state['requests'][-1][1].endswith('/undo')
    state['kind']='preview'
    resumed=run('voice-held-resume','--batch-id','batch-1','--confirm')
    assert resumed['details']['kind']=='preview' and state['requests'][-1][1].endswith('/resume')
    history=run('voice-held-batches')
    assert history['details']['batches'][0]['status']=='interrupted'
server.shutdown()
print('COS Control: isolated held naming transport passed (old-server no-write, preview/apply, statuses, raw triples, undo after deletion, resume)')
