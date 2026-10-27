#!/usr/bin/env python3
"""Real helper transport against disposable loopback; no production/provider commands."""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
root=pathlib.Path(tempfile.mkdtemp(prefix='cos-hardening-helper-',dir='/tmp'))
(root/'.cos-glasses').mkdir();(root/'.cos-glasses/.env').write_text('COS_API_TOKEN='+'a'*64+'\n')
calls=[];reason='meeting_finalizing';reply={}
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        calls.append((self.path,None));self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'sessionId':'meeting_fixture','recordId':'ops:personal:2026-10:merged.md','sourceRevision':'b'*64}).encode())
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));calls.append((self.path,body))
        if reply:
            self.send_response(reply['status']);self.end_headers();self.wfile.write(reply['raw'] if 'raw' in reply else json.dumps(reply['body']).encode());return
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
    # 0.5.351 (server 6.93.0): a Mac voice assigned to an existing profile crosses the helper as assignVoiceProfile, only when asked.
    relabel=('meeting-relabel','--session','mac_1b2c3d4e-0000-4000-8000-00000000abcd','--from','Voice 2','--to','Dana Reyes')
    preview={'ok':True,'enrolment':{'person':'Dana Reyes','enrolled':3,'attempted':5,'similarity':0.81,'belowFloor':False,'floor':0.55,'skipped':None}}
    reply.update(status=200,body=preview)
    res=run(*relabel,'--assign-voice-profile')
    assert calls[-1][1]['assignVoiceProfile'] is True and calls[-1][1]['dryRun'] is True and 'confirm' not in calls[-1][1],calls[-1]
    assert res['details']['state']=='preview' and res['details']['result']['enrolment']['enrolled']==3,res
    res=run(*relabel,'--assign-voice-profile','--confirm')
    assert calls[-1][1]['assignVoiceProfile'] is True and calls[-1][1]['confirm'] is True,calls[-1]
    assert res['details']['state']=='applied',res
    run(*relabel)
    assert 'assignVoiceProfile' not in calls[-1][1],calls[-1]
    # A name that is not an enrolled profile is the server's answer, not a missing route; an HTML 404 still is a missing route.
    reply.clear();reply.update(status=404,body={'reason':'unknown_profile','error':'Dana Reyes is not an enrolled voice profile'})
    res=run(*relabel,'--assign-voice-profile')
    assert res['details']['state']=='declined' and 'not an enrolled' in res['details']['result']['error'],res
    reply.clear();reply.update(status=404,raw=b'<html>Cannot POST</html>')
    assert run(*relabel,'--assign-voice-profile')['details']['state']=='route_missing'
    reply.clear();reply.update(status=404,body={'reason':'meeting_not_found','error':'No saved meeting'})
    assert run(*relabel)['details']['state']=='route_missing'
    # nothing_to_enrol is a 422 decline that carries the reason block.
    reply.clear();reply.update(status=422,body={'reason':'nothing_to_enrol','error':'No usable audio','enrolment':{'person':'Dana Reyes','skipped':'audio_not_retained'}})
    res=run(*relabel,'--assign-voice-profile','--confirm')
    assert res['details']['state']=='declined' and res['details']['result']['enrolment']['skipped']=='audio_not_retained',res
    # 0.5.351 QA W4: a 400 that says the assignment does not apply is the server's answer, not its confirmation gate.
    for why in ('not_a_voice_label','not_mac_capture'):
        reply.clear();reply.update(status=400,body={'reason':why,'error':'Only an unnamed Voice N can be assigned to a voice profile'})
        res=run(*relabel,'--assign-voice-profile','--confirm')
        assert res['details']['state']=='declined' and res['details']['reason']==why and 'unnamed Voice N' in res['details']['result']['error'],res
    # The confirmation gate is still a 400 preview (no reason, or confirmation_required).
    reply.clear();reply.update(status=400,body={'reason':'confirmation_required','error':'confirmation required','enrolment':{'person':'Dana Reyes','enrolled':3}})
    res=run(*relabel,'--assign-voice-profile')
    assert res['details']['state']=='preview' and res['details']['result']['enrolment']['enrolled']==3,res
    # QA B1: a 409 gate carries its reason and the measured enrolment block; force crosses only when asked.
    for why in ('below_floor','mixed_voice','too_little_audio','owner_profile','capture_active','meeting_changed','assign_in_progress'):
        reply.clear();reply.update(status=409,body={'reason':why,'error':'Nothing was changed','gates':[why],'enrolment':{'person':'Dana Reyes','enrolled':3,'attempted':5,'clusterSkipped':2,'gates':[why]}})
        res=run(*relabel,'--assign-voice-profile','--confirm')
        assert res['details']['state']=='declined' and res['details']['reason']==why and res['details']['result']['enrolment']['clusterSkipped']==2,res
        assert 'force' not in calls[-1][1],calls[-1]
    reply.update(status=200,body={'ok':True,'enrolment':{'person':'Dana Reyes','enrolled':3}})
    res=run(*relabel,'--assign-voice-profile','--confirm','--force')
    assert calls[-1][1]['force'] is True and calls[-1][1]['assignVoiceProfile'] is True and calls[-1][1]['confirm'] is True and res['details']['state']=='applied',calls[-1]
    reply.clear()
    for command,route in [('meeting-speakers','speakers'),('meeting-content','content')]:
        assert run(command,'--session','meeting_fixture','--record-id','ops:personal:2026-10:merged.md')['ok']
        assert calls[-1][0]=='/api/meeting/meeting_fixture/'+route+'?recordId=ops%3Apersonal%3A2026%2D10%3Amerged%2Emd',calls[-1]
    print('PASS: selected record and source revision cross compiled helper; six 409 recovery cases, including a missing reason; Mac voice assignment flag, unknown profile 404, nothing_to_enrol 422, not_a_voice_label 400, seven 409 gates, force only when asked')
finally:
    server.shutdown();shutil.rmtree(root)
