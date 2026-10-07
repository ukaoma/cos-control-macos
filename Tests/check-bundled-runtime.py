#!/usr/bin/env python3
"""Exercise the packaged runtime, without launching a server or touching user data."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

resources = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="cos-runtime-check-", dir="/tmp") as tmp:
    home = Path(tmp) / "home"
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", COS_CONTROL_TEST_HOME=str(home))
    helper = resources / "cos-control-helper"
    first = subprocess.run([str(helper), "self-test-bundled-runtime"], env=env, check=True, capture_output=True, text=True)
    receipt = json.loads(first.stdout)
    assert receipt["ok"]
    node = Path(receipt["details"]["node"])
    assert node.is_relative_to(home)
    assert not (home / "Library/LaunchAgents/com.cos.glasses-server.plist").exists()
    before = node.stat().st_mtime_ns
    # The retained helper must work after the downloaded app moves or updates:
    # there is deliberately no BundledNode alongside this second executable.
    stable = Path(tmp) / "stable-helper"
    shutil.copy2(helper, stable)
    second = subprocess.run([str(stable), "self-test-bundled-runtime"], env=env, check=True, capture_output=True, text=True)
    assert json.loads(second.stdout)["ok"]
    assert node.stat().st_mtime_ns == before, "Retry must not replace a running runtime"
    print("PASS: bundled Node/npm with Finder PATH, isolated home, no server, idempotent retry, relocated helper")
