#!/usr/bin/env python3
"""Real-package canary using a notarized ZIP, isolated files/ports, no desktop UI.

This exercises the packaged helper's runtime preparation and the installer's npm
commands, then the published server's real provider-proof endpoint. It does NOT
exercise launchd registration, a clean macOS account, TCC, or the updater swap.
Requires an existing Codex login; copies only auth.json into disposable storage.
Logs never include that file or the generated API token. No production services
are stopped, adopted, or restarted. Run manually, not as an ordinary unit test.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', required=True, type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--server-version', required=True)
    parser.add_argument('--codex', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = {'archive': str(args.zip), 'checks': {}, 'limitations': [
        'Disposable home on an existing Mac, not a clean macOS VM/account.',
        'Packaged helper prepares runtime; server npm install commands match stageGeneration, but helper setup transaction is not invoked.',
        'Server foreground launch; launchd registration and app updater not exercised.',
        'One existing Codex login; no interactive signup or TCC tested.',
    ]}
    assert sha256(args.zip) == args.sha256, 'Archive hash mismatch'
    receipt['sha256'] = args.sha256
    process = None
    secret_copy = None
    with tempfile.TemporaryDirectory(prefix='cos-onboarding-canary-', dir='/tmp') as scratch:
        root = Path(scratch)
        test_home = root / 'home'
        test_home.mkdir(mode=0o700)
        server_log = None
        token = secrets.token_urlsafe(32)
        def run(cmd, label, *, env=None, sandbox=False, timeout=120):
            if sandbox:
                cmd = ['/usr/bin/sandbox-exec', '-f', str(policy)] + list(map(str, cmd))
            result = subprocess.run(list(map(str, cmd)), cwd=root, env=env,
                                    capture_output=True, text=True, timeout=timeout)
            output = (result.stdout + '\n' + result.stderr).replace(token, '[redacted]')
            (args.output / (label + '.log')).write_text(output)
            if result.returncode:
                raise RuntimeError(f'{label} failed ({result.returncode}); see {label}.log')
            return result.stdout
        try:
            run(['/usr/bin/ditto', '-x', '-k', args.zip, root], 'extract')
            app = root / 'COS Control.app'
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            receipt.update(version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'])
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], 'signature')
            run(['/usr/bin/xcrun', 'stapler', 'validate', app], 'staple')
            run(['/usr/sbin/spctl', '-a', '-vv', '--type', 'execute', app], 'gatekeeper')
            assert 'Notarized Developer ID' in (args.output / 'gatekeeper.log').read_text()
            receipt['checks']['notarized_archive'] = True
            # Deny host package managers and all live-home writes. The entire
            # signed bundle has already been copied outside the real home.
            policy = root / 'isolation.sb'
            policy.write_text('''(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "/private/tmp") (subpath "/tmp") (subpath %s) (literal "/dev/null"))
(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local") (subpath %s))
(deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/osascript") (literal "/usr/bin/open"))
(deny network-outbound (remote tcp "localhost:3141") (remote tcp "localhost:3143")
 (remote tcp "localhost:8178") (remote tcp "localhost:8179") (remote tcp "localhost:8180"))
''' % (json.dumps(str(Path(subprocess.check_output(['/usr/bin/getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip()).resolve())), json.dumps(str(Path.home()))))
            env = {'HOME': str(test_home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                   'TMPDIR': str(root), 'LANG': 'en_US.UTF-8',
                   'COS_CONTROL_TEST_HOME': str(test_home)}
            run(['/bin/sh', '-c', 'test ! -r /opt/homebrew/bin/node && test ! -r /usr/local/bin/node && ! command -v node && ! command -v npm && ! command -v npx'],
                'no-host-node', env=env, sandbox=True)
            helper = app / 'Contents/Resources/cos-control-helper'
            prepared = json.loads(run([helper, 'self-test-bundled-runtime'], 'prepare-runtime', env=env, sandbox=True))
            assert prepared['ok']
            node = Path(prepared['details']['node'])
            assert node.is_relative_to(test_home)
            runtime_bin = node.parent
            env['PATH'] = str(runtime_bin) + ':' + env['PATH']
            npm = runtime_bin / 'npm'
            receipt['checks']['bundled_runtime_without_host_node'] = True
            print('PASS: notarization, staple, Gatekeeper, bundled runtime without host Node', flush=True)
            manifest = json.loads(run([npm, 'view', '@gotcos/glasses-server@' + args.server_version,
                                      'version', 'dist.integrity', '--json'], 'registry', env=env, sandbox=True))
            assert manifest['version'] == args.server_version
            stage = root / 'server'
            stage.mkdir()
            packed = json.loads(run([npm, '--silent', 'pack', '@gotcos/glasses-server@' + args.server_version,
                                    '--pack-destination', stage, '--json'], 'pack', env=env, sandbox=True))
            tarball = stage / packed[0]['filename']
            integrity = 'sha512-' + base64.b64encode(hashlib.sha512(tarball.read_bytes()).digest()).decode()
            assert integrity == manifest['dist.integrity']
            run([npm, 'install', '--prefix', stage, '--ignore-scripts', '--omit=dev', '--no-audit', '--no-fund', tarball],
                'install', env=env, sandbox=True, timeout=900)
            receipt.update(serverVersion=args.server_version, registryIntegrity=integrity)
            receipt['checks']['real_registry_install'] = True
            package = stage / 'node_modules/@gotcos/glasses-server'
            print('PASS: actual npm package and dependencies installed; registry integrity matches', flush=True)
            # Test idempotent preparation from a relocated retained helper.
            retained = root / 'retained-helper'
            shutil.copy2(helper, retained)
            before = node.stat().st_mtime_ns
            assert json.loads(run([retained, 'self-test-bundled-runtime'], 'retry-runtime', env=env, sandbox=True))['ok']
            assert node.stat().st_mtime_ns == before
            receipt['checks']['retry_and_relocated_helper'] = True
            provider_bin = root / 'provider-bin'
            provider_bin.mkdir()
            (provider_bin / 'codex').symlink_to(args.codex.resolve())
            auth_dir = test_home / '.codex'
            auth_dir.mkdir(mode=0o700)
            secret_copy = auth_dir / 'auth.json'
            port, https_port = free_port(), free_port()
            assert port != https_port and not {port, https_port} & {3141, 3143}
            env.update(PATH=str(provider_bin) + ':' + env['PATH'], PORT=str(port),
                       HTTPS_PORT=str(https_port), BIND_HOST='127.0.0.1',
                       COS_API_TOKEN=token, COS_MANAGED='1', COS_ENTRYPOINT='cos-control',
                       COS_SERVER_VERSION=args.server_version, COS_SERVER_GENERATION_ID='onboarding-canary',
                       COS_DATA_DIR=str(root / 'data'), COS_SESSION_HOOKS='0')
            tsx = stage / 'node_modules/tsx/dist/esm/index.mjs'
            server_log = (root / 'server.log').open('w')
            process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy), str(node), '--import', str(tsx),
                                        str(package / 'server/index.ts')], cwd=package, env=env,
                                       stdin=subprocess.DEVNULL, stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
            def request(route, data=None, authenticated=True):
                headers = {'Content-Type': 'application/json'}
                if authenticated:
                    headers['X-Cos-Token'] = token
                req = urllib.request.Request(f'http://127.0.0.1:{port}{route}',
                    data=json.dumps(data).encode() if data is not None else None, headers=headers)
                with urllib.request.urlopen(req, timeout=135 if data else 5) as response:
                    return json.load(response)
            deadline = time.monotonic() + 75
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('Server exited; see server.log')
                try:
                    health = request('/api/health')
                    break
                except (OSError, urllib.error.URLError):
                    time.sleep(1)
            else:
                raise RuntimeError('Server health timed out')
            (args.output / 'health.json').write_text(json.dumps(health, indent=2).replace(token, '[redacted]'))
            receipt['checks']['server_health'] = True
            print('PASS: real managed server started on isolated loopback port', flush=True)
            try:
                request('/api/diagnostics/provider-proof', {'provider': 'codex'}, authenticated=False)
                raise AssertionError('Unauthenticated API request was accepted')
            except urllib.error.HTTPError as error:
                assert error.code == 401, error.code
            receipt['checks']['api_auth_required'] = True
            try:
                request('/api/diagnostics/provider-proof', {'provider': 'codex'})
                raise AssertionError('Provider without login was treated as ready')
            except urllib.error.HTTPError as error:
                missing_login = json.load(error)
                assert error.code == 503 and missing_login.get('code') == 'provider_auth', missing_login
                (args.output / 'missing-login.json').write_text(json.dumps(missing_login, indent=2))
            receipt['checks']['missing_login_blocks_readiness'] = True
            shutil.copyfile(Path.home() / '.codex/auth.json', secret_copy)
            secret_copy.chmod(0o600)
            proof = request('/api/diagnostics/provider-proof', {'provider': 'codex'})
            (args.output / 'provider-proof.json').write_text(json.dumps(proof, indent=2))
            assert proof['ok'] and not proof['cached'], proof
            receipt['checks']['real_codex_request'] = True
            receipt['checks']['login_retry_recovers'] = True
            receipt['providerProof'] = proof
            print('PASS: real uncached Codex request through the installed server', flush=True)
            receipt['result'] = 'passed'
        except Exception as error:
            receipt['result'] = 'failed'
            receipt['error'] = str(error).replace(token, '[redacted]')
            raise
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            if server_log:
                server_log.close()
                path = args.output / 'server.log'
                path.write_text((root / 'server.log').read_text().replace(token, '[redacted]'))
            if secret_copy:
                secret_copy.unlink(missing_ok=True)
            (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
