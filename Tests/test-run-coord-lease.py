#!/usr/bin/env python3
"""No Swift: exercise run.sh's exact lease integration against real coord.py in scratch state.

Run with --coord-py <MU operations/scripts/coord.py>. Neither its registry nor its prose
log is used: every fixture supplies both private paths and private HOME/COS_DATA_DIR.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
parser.add_argument('--coord-py', type=Path, required=True)
args = parser.parse_args()
ROOT = args.root.resolve()
COORD = args.coord_py.resolve()


class LeaseIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cos-run-coord-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.state = self.root / 'coord-state'
        self.prose = self.root / 'COORD.md'
        self.prose.write_text('# Disposable coordination\n')
        self.children = []

    def tearDown(self):
        for child in self.children:
            # Each fixture owns a separate session. Mutants which skip the real
            # EXIT cleanup must not leave their synthetic children or pipes alive.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError:
                # macOS can return EPERM for a session whose last process has
                # already exited. A live owned fixture is still an error.
                if child.poll() is None:
                    raise
            try:
                child.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    if child.poll() is None:
                        raise
                child.communicate(timeout=4)
        self.temp.cleanup()

    def fixture(self, probe, extra=None):
        checkout = self.root / ('checkout-' + str(len(list(self.root.glob('checkout-*')))))
        (checkout / 'Tests').mkdir(parents=True)
        (checkout / 'home').mkdir()
        lines = (ROOT / 'Tests/run.sh').read_text().splitlines()
        cut = next(i for i, line in enumerate(lines) if line.startswith('/usr/bin/python3 "$ROOT/Tests/desktop-safety-check.py"'))
        begin = next((i for i, line in enumerate(lines) if line == '# COORD_SWIFT_LEASE_BEGIN'), None)
        end = next((i for i, line in enumerate(lines) if line == '# COORD_SWIFT_LEASE_END'), None)
        block = lines[begin:end + 1] if begin is not None and end is not None else []
        helper = ROOT / 'Tests/coord-swift-lease.zsh'
        if helper.exists():
            shutil.copyfile(helper, checkout / 'Tests/coord-swift-lease.zsh')
        script = checkout / 'Tests/run.sh'
        script.write_text('\n'.join(lines[:cut] + block + probe) + '\n')
        env = dict(os.environ, HOME=str(checkout / 'home'), COS_DATA_DIR=str(checkout / 'data'), TMPDIR=str(self.root),
                   COS_SUITE_LOG_DIR=str(checkout / 'logs'), COS_TEST_KIT_PERSIST='0', COS_COORD_LEASES='1',
                   COS_COORD_PY=str(COORD), COS_COORD_STATE_DIR=str(self.state), COS_COORD_FILE=str(self.prose),
                   COS_COORD_LANE='same-fixture-prefix', COS_COORD_LEASE_TTL_MIN='0.04', COS_COORD_LEASE_RENEW_SECONDS='0.2')
        env.pop('COS_SCRIPTS_DIR', None)
        env.update(extra or {})
        return script, env

    def start(self, probe, extra=None):
        script, env = self.fixture(probe, extra)
        child = subprocess.Popen(['/bin/zsh', str(script)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
        self.children.append(child)
        return child

    def run_fixture(self, probe, extra=None):
        child = self.start(probe, extra)
        try:
            out, err = child.communicate(timeout=8)
        except subprocess.TimeoutExpired:
            self.fail('fixture failed to terminate within its bounded deadline')
        return child.returncode, out, err

    def lease(self):
        path = self.state / 'leases/swift-slot.json'
        return json.loads(path.read_text()) if path.exists() else None

    def wait_lease(self):
        until = time.monotonic() + 4
        while time.monotonic() < until:
            lease = self.lease()
            if lease:
                return lease
            time.sleep(0.03)
        self.fail('run.sh must acquire a real disposable coordination lease before its work')

    def records(self):
        path = self.state / 'claims.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_one_lease_cycle(self, records):
        operations = [(row['kind'], row['op']) for row in records]
        self.assertGreaterEqual(len(operations), 2)
        self.assertEqual(operations[0], ('lease', 'acquire'))
        self.assertEqual(operations[-1], ('release', 'release'))
        self.assertEqual(operations.count(('release', 'release')), 1)
        self.assertTrue(all(op == ('lease', 'renew') for op in operations[1:-1]))

    def test_normal_and_failure_exit_release_once_and_preserve_status(self):
        for code in (0, 7):
            with self.subTest(code=code):
                before = len(self.records())
                actual, out, err = self.run_fixture(['print entered-work', 'exit ' + str(code)])
                self.assertEqual(actual, code, err)
                self.assertIn('entered-work', out)
                self.assertIsNone(self.lease())
                records = self.records()[before:]
                self.assert_one_lease_cycle(records)

    def test_competing_suite_refused_even_with_same_caller_lane_prefix(self):
        first = self.start(['sleep 3'])
        held = self.wait_lease()
        code, out, err = self.run_fixture(['print must-not-enter'])
        self.assertEqual(code, 3, (out, err))
        self.assertNotIn('must-not-enter', out)
        self.assertIn('HELD swift-slot', out)
        self.assertEqual(self.lease()['lane'], held['lane'])
        first.terminate()
        first.communicate(timeout=5)
        self.assertIsNone(self.lease())

    def test_heartbeat_renews_past_original_expiry_and_stays_exclusive(self):
        first = self.start(['sleep 3'], {'COS_COORD_LEASE_TTL_MIN': '0.02'})
        held = self.wait_lease()
        time.sleep(1.5)  # Original TTL was 1.2 seconds; renewal must be real, not merely configured.
        current = self.lease()
        self.assertIsNotNone(current)
        self.assertIsNotNone(current.get('renewed'))
        self.assertTrue(any(row.get('op') == 'renew' for row in self.records()))
        code, out, err = self.run_fixture(['print must-not-enter'])
        self.assertEqual(code, 3, (out, err))
        self.assertEqual(self.lease()['lane'], held['lane'])
        first.terminate()
        first.communicate(timeout=5)
        self.assertIsNone(self.lease())
        count = len(self.records())
        time.sleep(0.35)
        self.assertEqual(len(self.records()), count, 'heartbeat must stop before release, without a late renewal')

    def test_term_and_int_release_after_existing_background_cleanup(self):
        for sig, code in ((signal.SIGTERM, 143), (signal.SIGINT, 130)):
            with self.subTest(sig=sig):
                marker = self.root / ('cleanup-' + str(sig))
                lease_path = self.state / 'leases/swift-slot.json'
                probe = [
                    '( trap \'[[ -f "$LEASE_PATH" ]] && print held > "$STOP_MARKER"; exit 0\' TERM INT; while true; do sleep 0.1; done ) &',
                    'APP_BUILD_PID=$!', 'while true; do sleep 0.1; done',
                ]
                child = self.start(probe, {'LEASE_PATH': str(lease_path), 'STOP_MARKER': str(marker)})
                self.wait_lease()
                time.sleep(0.15)
                child.send_signal(sig)
                out, err = child.communicate(timeout=5)
                self.assertEqual(child.returncode, code, (out, err))
                self.assertTrue(marker.exists(), 'existing background cleanup must run before lease release')
                self.assertIsNone(self.lease())

    def test_disabled_modes_do_not_touch_coordination_or_require_tool(self):
        for value in ('', '0', 'false', 'garbage', 't rue'):
            with self.subTest(value=value):
                code, out, err = self.run_fixture(['print entered-work'], {'COS_COORD_LEASES': value, 'COS_COORD_PY': '/missing/coord.py'})
                self.assertEqual(code, 0, err)
                self.assertIn('entered-work', out)
                self.assertFalse(self.state.exists(), 'off/default means no registry or shadow writes')

    def test_enabled_missing_tool_and_invalid_timings_refuse_before_work(self):
        for extra in ({'COS_COORD_PY': '/missing/coord.py'}, {'COS_COORD_LEASE_TTL_MIN': '0'}, {'COS_COORD_LEASE_RENEW_SECONDS': '100'}):
            with self.subTest(extra=extra):
                code, out, err = self.run_fixture(['print must-not-enter'], extra)
                self.assertEqual(code, 2, (out, err))
                self.assertNotIn('must-not-enter', out)
                self.assertFalse(self.state.exists())

    def test_renewal_failure_stops_suite_and_releases_after_heartbeat(self):
        proxy = self.root / 'fail-renew.py'
        proxy.write_text('import os,sys\n'
                         'if "renew" in sys.argv[1:]: sys.exit(9)\n'
                         'os.execv(sys.executable, [sys.executable, ' + repr(str(COORD)) + '] + sys.argv[1:])\n')
        code, out, err = self.run_fixture(['while true; do sleep 0.1; done'], {'COS_COORD_PY': str(proxy)})
        self.assertEqual(code, 70, (out, err))
        self.assertIn('renewal failed', err)
        self.assertIsNone(self.lease())
        count = len(self.records())
        time.sleep(0.35)
        self.assertEqual(len(self.records()), count)

    def test_trimmed_enabled_mode_and_subcentisecond_interval(self):
        code, out, err = self.run_fixture(['print entered-work'], {'COS_COORD_LEASES': ' YES ', 'COS_COORD_LEASE_RENEW_SECONDS': '0.001'})
        self.assertEqual(code, 0, (out, err))
        self.assertIn('entered-work', out)
        self.assertIsNone(self.lease())
        self.assert_one_lease_cycle(self.records())

    def test_integration_keeps_one_exit_trap_and_actual_compile_guard(self):
        source = (ROOT / 'Tests/run.sh').read_text()
        self.assertEqual(sum(line.startswith('trap ') and line.endswith(' EXIT') for line in source.splitlines()), 1)
        self.assertIn('"$ROOT/Tests/compile-guard.sh" swiftc', source)
        self.assertIn('_app_build_stop', source)
        trap = next(line for line in source.splitlines() if line.startswith('trap ') and line.endswith(' EXIT'))
        self.assertIn('_coord_lease_release', trap)
        self.assertLess(trap.index('_app_build_stop'), trap.index('_coord_lease_release'), 'background cleanup precedes lease release')


if __name__ == '__main__':
    unittest.main(argv=[__file__], verbosity=2)
