#!/usr/bin/env python3
"""Real macOS startup probe for the isolated Activity-shell QA executable.
Requires an already running disposable backend and matching COS_CONTROL_TEST_* env.
Never starts/stops a backend or another app process.
"""
import os, pathlib, subprocess, sys, tempfile
app = pathlib.Path(sys.argv[1])
binary = app / 'Contents/MacOS/COS Control Foundation Lab'
assert os.environ.get('COS_CONTROL2_FOUNDATION') == '1'
assert os.environ.get('COS_CONTROL_TEST_HOME', '').startswith('/tmp/')
assert os.environ.get('COS_CONTROL_TEST_API_PORT') not in (None, '3141', '3143')
for appearance in ('light', 'dark'):
    with tempfile.TemporaryFile(mode='w+') as log:
        env = dict(os.environ, COS_CONTROL_TEST_APPEARANCE=appearance)
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
        try:
            try:
                code = process.wait(timeout=3)
                log.seek(0)
                raise AssertionError(f'{appearance} preview exited {code}: {log.read()[-2000:]}')
            except subprocess.TimeoutExpired:
                print(f'PASS: actual {appearance} Activity-shell preview remained alive after startup')
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
