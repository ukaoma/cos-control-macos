#!/usr/bin/env python3
"""Real signed-runtime install, repeat install and corruption refusal in disposable homes.
No launchd, Homebrew, live settings, or user models. Run with compiled helper and release archive.
"""
import hashlib,json,os,pathlib,shutil,subprocess,sys,tempfile,signal,time
root=pathlib.Path(__file__).resolve().parents[1]
helper=pathlib.Path(sys.argv[1]);archive=pathlib.Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix='cos-whisper-check-',dir='/tmp') as scratch:
    scratch=pathlib.Path(scratch);resources=scratch/'Resources';resources.mkdir()
    shutil.copy2(helper,resources/'cos-control-helper')
    shutil.copy2(root/'Resources/whisper-runtime.json',resources)
    shutil.copytree(root/'Resources/VoiceBenchmark',resources/'VoiceBenchmark')
    home=scratch/'new Mac';home.mkdir()
    env={**os.environ,'COS_CONTROL_TEST_HOME':str(home),'HOME':str(home),'PATH':'/usr/bin:/bin:/usr/sbin:/sbin'}
    def run(file):
        return subprocess.run([str(resources/'cos-control-helper'),'self-test-whisper-runtime',str(file)],env=env,text=True,capture_output=True,timeout=90)
    first=run(archive);assert first.returncode==0,first.stdout+first.stderr
    again=run(archive);assert again.returncode==0,again.stdout+again.stderr
    print('PASS: signed runtime installs and retries with system-only PATH')
    binaries=list(home.rglob('whisper-cli'));assert len(binaries)==1
    links=subprocess.check_output(['/usr/bin/otool','-L',str(binaries[0])],text=True)
    assert '/opt/homebrew/' not in links and '/usr/local/' not in links
    print('PASS: no Homebrew dylib dependency')
    # Real helper and signed Whisper, fixture model-preparation process. Existing model is read-only.
    model=pathlib.Path.home()/'.local/share/whisper-models/ggml-large-v3-turbo.bin'
    if model.is_file():
        models=home/'.local/share/whisper-models';models.mkdir(parents=True)
        (models/model.name).symlink_to(model)
        generation=home/'gen';cli=generation/'node_modules/@gotcos/glasses-server/bin/cli.cjs';cli.parent.mkdir(parents=True)
        cli.write_text('// --voice-benchmark-prepare --preserve-voice-settings\n')
        node=home/'fixture-node';node.write_text('#!/bin/sh\nif [ -n "$SLOW" ]; then sleep 121.75 & echo $! > "$HOME/child.pid"; wait; fi\necho "Transcription setup complete"\n');node.chmod(0o700)
        runtime=home/'Library/Application Support/COS Control/runtime'
        (runtime/'active.json').write_text(json.dumps({'version':'6.65.0','generationPath':str(generation),'installedAt':'2026-10-08T00:00:00Z','previousVersions':[],'nodePath':str(node)}))
        config=home/'.cos-glasses/.env';config.parent.mkdir(exist_ok=True)
        settings='COS_WHISPER_TRANSCRIPTION_TIER=max\nCOS_WHISPER_PREVIEW_MODEL=turbo\nCOS_WHISPER_COMMIT_MODEL=large-v3\nOTHER=kept\n'
        config.write_text(settings);config.chmod(0o600)
        # Recover an interrupted older onboarding helper's snapshot before preparation.
        snapshot = runtime.parent/'voice-setup-env-snapshot.json'
        snapshot.write_text(json.dumps({'values':dict(line.split('=',1) for line in settings.splitlines() if line.startswith('COS_WHISPER_'))}))
        config.write_text(settings.replace('=max','=balanced').replace('=large-v3','=turbo'))
        env['COS_CONTROL_TEST_API_PORT']='49197'
        result=subprocess.run([str(resources/'cos-control-helper'),'voice-setup','auto'],env=env,text=True,capture_output=True,timeout=240)
        assert result.returncode==0,result.stdout+result.stderr
        receipt=json.loads((runtime.parent/'voice-benchmark.json').read_text())
        assert receipt['preparedTier']=='max' and receipt['setupComplete'] and receipt['realTimeFactor']>0
        assert config.read_text()==settings and not snapshot.exists()
        print('PASS: interrupted older setup snapshot restores Max before preparation')
        kept=subprocess.run([str(resources/'cos-control-helper'),'voice-apply-recommendation'],env=env,text=True,capture_output=True,timeout=30)
        assert kept.returncode==0 and 'kept' in kept.stdout,kept.stdout+kept.stderr
        assert config.read_text()==settings
        print('PASS: real 30-second Metal benchmark saves measurements and preserves existing Max')
        slow=subprocess.Popen([str(resources/'cos-control-helper'),'voice-setup','auto'],env={**env,'SLOW':'1'},text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        marker=home/'child.pid'
        for _ in range(200):
            if marker.exists(): break
            time.sleep(.1)
        assert marker.exists(),'fixture download did not start'
        slow.send_signal(signal.SIGTERM);stdout,stderr=slow.communicate(timeout=20)
        child=int(marker.read_text())
        time.sleep(.2)
        assert subprocess.run(['/bin/kill','-0',str(child)],capture_output=True).returncode!=0,'orphan child'
        assert slow.returncode!=0 and config.read_text()==settings
        print('PASS: Cancel stops the entire preparation group and keeps Max')
    bad=scratch/'bad.zip';bad.write_bytes(b'not a verified runtime')
    other=scratch/'bad home';other.mkdir();env['COS_CONTROL_TEST_HOME']=env['HOME']=str(other)
    failed=run(bad);assert failed.returncode!=0 and 'checksum' in failed.stdout.lower(),failed.stdout+failed.stderr
    assert not list(other.rglob('receipt.json'))
    assert not list(other.rglob('.stage-*'))
    print('PASS: corrupted archive rejected before extraction and stage cleaned')
    assert not (other/'.cos-glasses/.env').exists()
    print('PASS: setup did not write voice settings')
