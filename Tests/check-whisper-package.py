#!/usr/bin/env python3
"""Candidate package + signed tools in a disposable home, system PATH and bundled Node.
Existing model bytes are read-only symlinks. No launchd or live settings are touched.
"""
import json, os, pathlib, shutil, socket, subprocess, sys, tempfile, time, urllib.request
repo = pathlib.Path(__file__).resolve().parents[1]
helper, archive, package, dependencies = map(pathlib.Path, sys.argv[1:5])
node = pathlib.Path('/Applications/COS Control.app/Contents/Resources/BundledNode/bin/node')
assert node.is_file(), 'Provide an installed COS bundled Node for this developer canary'
with tempfile.TemporaryDirectory(prefix='cos-whisper-package-', dir='/tmp') as scratch:
    root = pathlib.Path(scratch); home = root/'new Mac'; home.mkdir()
    resources = root/'Resources'; resources.mkdir()
    shutil.copy2(helper, resources/'cos-control-helper')
    shutil.copy2(repo/'Resources/whisper-runtime.json', resources)
    shutil.copytree(repo/'Resources/VoiceBenchmark', resources/'VoiceBenchmark')
    env = {'HOME':str(home), 'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'COS_CONTROL_TEST_HOME':str(home), 'COS_CONTROL_TEST_API_PORT':'49197'}
    def call(*args, timeout=240):
        result = subprocess.run([str(resources/'cos-control-helper'), *args], env=env, capture_output=True, text=True, timeout=timeout)
        assert result.returncode == 0, result.stdout+result.stderr
        return json.loads(result.stdout)
    call('self-test-whisper-runtime', str(archive))
    generation = home/'generation'; generation.mkdir()
    subprocess.run(['/usr/bin/tar','-xzf',str(package),'-C',str(generation)], check=True)
    installed = generation/'node_modules/@gotcos/glasses-server'; installed.parent.mkdir(parents=True)
    (generation/'package').rename(installed)
    (installed/'node_modules').symlink_to(dependencies.resolve(), target_is_directory=True)
    runtime = home/'Library/Application Support/COS Control/runtime'
    (runtime/'active.json').write_text(json.dumps({'version':'6.66.0','generationPath':str(generation), 'installedAt':'2026-10-08T00:00:00Z','previousVersions':[], 'nodePath':str(node)}))
    provider = home/'.local/bin/claude'; provider.parent.mkdir(parents=True)
    provider.write_text("#!/bin/sh\nif [ \"$1\" = auth ]; then echo '{\"loggedIn\":true}'; else echo 'Claude Code 1.0.0'; fi\n"); provider.chmod(0o700)
    env['PATH'] = str(provider.parent)+':/usr/bin:/bin:/usr/sbin:/sbin'
    models = home/'.local/share/whisper-models'; models.mkdir(parents=True)
    for name in ['ggml-large-v3-turbo.bin','ggml-large-v3.bin','ggml-small.en.bin']:
        source = pathlib.Path.home()/'.local/share/whisper-models'/name
        assert source.is_file(), 'Cached model needed: '+name
        (models/name).symlink_to(source)
    config = home/'.cos-glasses'; config.mkdir(exist_ok=True)
    (config/'models').mkdir()
    voiceprint = pathlib.Path.home()/'.cos-glasses/models/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx'
    (config/'models'/voiceprint.name).symlink_to(voiceprint)
    result = call('voice-setup','auto')
    facts = call('voice-status')['details']
    assert facts['explicitTier'] is None, facts
    receipt = json.loads((runtime.parent/'voice-benchmark.json').read_text())
    assert receipt['setupComplete'] and receipt['preparedTier']==receipt['recommendedTier'], receipt
    settings = (config/'.env').read_text() if (config/'.env').exists() else ''
    assert not any(line.strip().startswith('COS_WHISPER_TRANSCRIPTION_TIER=') for line in settings.splitlines())
    print('PASS: real npm candidate prepares new-user recommendation using bundled Node, provider fixture, and no global package tools')
    print('METRICS:',json.dumps({k:receipt[k] for k in ['chip','memoryBytes','engineSeconds','elapsedSeconds','realTimeFactor','recommendedTier','metal']},sort_keys=True))
    # Check the daemon, not just the CLI: same local HTTP contract COS uses.
    binary = next(runtime.rglob('whisper-server'))
    imports = f"const local=await import({json.dumps((installed/'server/lib/whisper-local.ts').as_uri())}); await import({json.dumps((installed/'server/lib/whisper-preview.ts').as_uri())}); if(!local.getWhisperHealth().serverConfigured) throw new Error('Explicit server path was not resolved'); console.log('packaged module imports passed'); process.exit(0);"
    probe = subprocess.run([str(node),'--import','tsx/esm','--input-type=module','-e',imports],cwd=installed,env={**env,'COS_WHISPER_SERVER_BIN':str(binary),'COS_WHISPER_CLI_BIN':str(binary.parent/'whisper-cli')},capture_output=True,text=True,timeout=30)
    assert probe.returncode==0,probe.stdout+probe.stderr
    print('PASS: packaged live and preview modules import with bundled Node and resolve managed binaries')
    with socket.socket() as available:
        available.bind(('127.0.0.1',0)); port = available.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    with (root/'server.log').open('w') as log:
        child = subprocess.Popen([str(binary),'-m',str(models/'ggml-large-v3-turbo.bin'),'-t','4','-l','en','-fa','--host','127.0.0.1','--port',str(port)],env=env,stdout=log,stderr=log)
        try:
            ready=False
            for _ in range(240):
                assert child.poll() is None, (root/'server.log').read_text()
                try:
                    with urllib.request.urlopen(url+'/health',timeout=1) as response:
                        if response.status==200: ready=True; break
                except Exception: pass
                time.sleep(.25)
            assert ready,'Whisper server failed to become ready'
            sample = resources/'VoiceBenchmark/speech-30s.wav'
            answer = subprocess.run(['/usr/bin/curl','--fail','--silent','--show-error','--max-time','30',url+'/inference','-F',f'file=@{sample}','-F','response_format=json','-F','suppress_non_speech=true'],capture_output=True,text=True)
            assert answer.returncode==0,answer.stderr
            text=json.loads(answer.stdout)['text']
            assert 'country' in text.lower() and len(text)>60,text
            print('PASS: signed whisper-server serves real 30-second speech through COS HTTP inference contract')
        finally:
            child.terminate()
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=10)
