#!/usr/bin/env python3
"""Watchdog tests use tiny Python children, never run a Swift compiler."""
import fcntl
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('bounded', Path(__file__).with_name('compile-bounded.py'))
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)
G = bounded.GIB


class BoundedTests(unittest.TestCase):
    def test_normalization_is_serial_and_rejects_overrides(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'main.swift'
            source.write_text('print("hello")')
            base = ['swiftc', '-target', 'arm64-apple-macosx14.0', '-swift-version', '6',
                    '-strict-concurrency=complete', str(source), '-o', directory + '/app']
            normalized = bounded.normalize(base, {})
            self.assertEqual(normalized[1:8], ['-j', '1', '-disable-batch-mode',
                                             '-no-whole-module-optimization', '-num-threads', '1', '-target'])
            for args in (['-j', '8'], ['-enable-batch-mode'], ['@args'], ['-Xfrontend', '-whole-module-optimization'], ['-driver-print-jobs']):
                with self.assertRaises(ValueError):
                    bounded.normalize(base + args, {})
            for key in ('COS_COMPILE_GUARD_HELD', 'COS_COMPILE_LOCK', 'COS_COMPILE_MAX_TOTAL_GB', 'SWIFT_EXEC'):
                with self.assertRaises(ValueError):
                    bounded.normalize(base, {key: ''})
            with self.assertRaises(ValueError):
                bounded.normalize(['/bin/zsh', '-c', 'swiftc'], {})

    def test_plan_requires_one_primary_per_frontend(self):
        self.assertEqual(bounded.validate_plan('/sdk/swift-frontend -frontend -c -primary-file a.swift b.swift -num-threads 1\n/sdk/clang a.o -o app'), 1)
        for plan in ('/sdk/swift-frontend -frontend -c a.swift',
                     '/sdk/swift-frontend -primary-file a.swift -primary-file b.swift',
                     '/sdk/swift-frontend -primary-file a.swift -num-threads 2',
                     '/sdk/swift-frontend -primary-file a.swift -whole-module-optimization',
                     '/bin/sh evil', ''):
            with self.assertRaises(ValueError):
                bounded.validate_plan(plan)

    def sample(self, available=20*G, rss=0, swap=0):
        return dict(availableBytes=available, rssBytes=rss, swapBytes=swap)

    def test_start_refusal_never_launches(self):
        result = bounded.run_owned(['/no/such/executable'], measure=lambda pid: self.sample(available=15*G))
        self.assertEqual(result['status'], 'refused')
        self.assertEqual(result['exitCode'], 75)

    def test_success_and_nonzero_exit_are_distinct(self):
        for exit_code, status in ((0, 'passed'), (3, 'failed')):
            result = bounded.run_owned([sys.executable, '-c', 'import sys,time; time.sleep(.05); sys.exit(' + str(exit_code) + ')'],
                                       measure=lambda pid: self.sample(rss=1024 if pid else 0), interval=.01)
            self.assertEqual(result['exitCode'], exit_code)
            self.assertEqual(result['status'], status)
            self.assertGreaterEqual(result['peakOwnedRSSBytes'], 1024)

    def test_each_resource_violation_stops_owned_group_only(self):
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        try:
            for sample, reason in ((self.sample(rss=9*G), 'RSS'),
                                   (self.sample(available=7*G), 'headroom'),
                                   (self.sample(swap=2*G), 'swap')):
                result = bounded.run_owned([sys.executable, '-c', 'import time; time.sleep(30)'],
                                           measure=lambda pid: sample if pid else self.sample(), interval=.01)
                self.assertEqual(result['exitCode'], 137)
                self.assertIn(reason, result['reason'])
                self.assertIsNone(unrelated.poll())
        finally:
            bounded.stop_group(unrelated)

    def test_timeout_stops_owned_child(self):
        result = bounded.run_owned([sys.executable, '-c', 'import time; time.sleep(30)'],
                                   measure=lambda pid: self.sample(), interval=.01, timeout=.03)
        self.assertEqual(result['exitCode'], 137)
        self.assertIn('time limit', result['reason'])

    def test_descendant_is_killed_even_when_it_ignores_term(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'child-pid'
            child_code = 'import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(' + repr(str(pidfile)) + ',"w").write(str(os.getpid())); time.sleep(30)'
            parent_code = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child_code) + ']); time.sleep(30)'
            def measure(pid):
                return self.sample(rss=9*G if pidfile.exists() else 0)
            result = bounded.run_owned([sys.executable, '-c', parent_code], measure=measure, interval=.01, timeout=5)
            self.assertEqual(result['status'], 'stopped')
            child_pid = int(pidfile.read_text())
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                state = subprocess.run(['/bin/ps', '-p', str(child_pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                if not state or state.startswith('Z'):
                    break
                time.sleep(.02)
            self.assertTrue(not state or state.startswith('Z'), state)

    def test_telemetry_failure_cleans_up_owned_child(self):
        process_id = []
        def fail(pid):
            if pid:
                process_id.append(pid)
                raise RuntimeError('measurement unavailable')
            return self.sample()
        with self.assertRaisesRegex(RuntimeError, 'measurement unavailable'):
            bounded.run_owned([sys.executable, '-c', 'import time; time.sleep(30)'], measure=fail)
        with self.assertRaises(ProcessLookupError):
            os.kill(process_id[0], 0)

    def test_bsd_lock_interoperates_with_system_lockf(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(Path(directory) / 'lock', 'w') as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', lock.name, '/usr/bin/true'], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                result = subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', lock.name, '/usr/bin/true'], capture_output=True)
                self.assertEqual(result.returncode, 0)

    def test_wrapper_sigkill_keeps_lock_until_guardian_kills_compiler(self):
        with tempfile.TemporaryDirectory() as directory:
            lockpath = Path(directory) / 'lock'
            pidfile = Path(directory) / 'compiler-pid'
            child = 'import os,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(' + repr(str(pidfile)) + ',"w").write(str(os.getpid())); time.sleep(30)'
            driver = 'import subprocess,sys,time; subprocess.Popen([sys.executable,\"-c\",' + repr(child) + '],start_new_session=True); time.sleep(30)'
            code = "import importlib.util,os,fcntl,sys; s=importlib.util.spec_from_file_location('b'," + repr(str(Path(bounded.__file__))) + "); b=importlib.util.module_from_spec(s); s.loader.exec_module(b); fd=os.open(" + repr(str(lockpath)) + ",os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(fd,fcntl.LOCK_EX); b.run_owned([sys.executable,'-c'," + repr(driver) + "],lock_fd=fd,measure=lambda pid: {'availableBytes':20*b.GIB,'rssBytes':0,'swapBytes':0})"
            wrapper = subprocess.Popen([sys.executable, '-c', code], start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(pidfile.exists())
                compiler_pid = int(pidfile.read_text())
                attempt = lambda: subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', str(lockpath), '/usr/bin/true'], capture_output=True).returncode
                self.assertNotEqual(attempt(), 0)
                os.kill(wrapper.pid, signal.SIGKILL)
                wrapper.wait()
                self.assertNotEqual(attempt(), 0, 'lock released before guardian cleanup')
                deadline = time.monotonic() + 3
                while attempt() != 0 and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(attempt(), 0, 'guardian never released lock')
                state = subprocess.run(['/bin/ps', '-p', str(compiler_pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not state or state.startswith('Z'), 'compiler survived wrapper SIGKILL')
            finally:
                if wrapper.poll() is None:
                    os.kill(wrapper.pid, signal.SIGKILL)
                    wrapper.wait()

    def test_kept_inode_holder_waiter_and_third_entrant(self):
        with tempfile.TemporaryDirectory() as directory:
            lockpath = Path(directory) / 'lock'
            ready = Path(directory) / 'ready'
            release = Path(directory) / 'release'
            code = "import pathlib,time; pathlib.Path(" + repr(str(ready)) + ").touch(); p=pathlib.Path(" + repr(str(release)) + "); limit=time.monotonic()+5\nwhile not p.exists() and time.monotonic()<limit: time.sleep(.01)"
            with open(lockpath, 'w') as holder:
                fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
                inode = lockpath.stat().st_ino
                waiter = subprocess.Popen(['/usr/bin/lockf', '-k', '-t', '5', str(lockpath), sys.executable, '-c', code])
                time.sleep(.1)
                self.assertFalse(ready.exists())
                fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
                deadline = time.monotonic() + 3
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                third = subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', str(lockpath), '/usr/bin/true'], capture_output=True)
                self.assertNotEqual(third.returncode, 0)
                self.assertEqual(lockpath.stat().st_ino, inode)
                release.touch()
                self.assertEqual(waiter.wait(), 0)
                self.assertEqual(lockpath.stat().st_ino, inode)
                third = subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', str(lockpath), '/usr/bin/true'], capture_output=True)
                self.assertEqual(third.returncode, 0)

    def test_separate_session_descendant_rss_is_measured_and_reaped(self):
        child = 'import time; data=bytearray(80*1024*1024); time.sleep(30)'
        driver = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + '],start_new_session=True); time.sleep(.5)'
        result = bounded.run_owned([sys.executable, '-c', driver],
                                   measure=lambda pid: self.sample(), interval=.01)
        self.assertEqual(result['status'], 'passed')
        self.assertGreater(result['peakOwnedRSSBytes'], 70*1024*1024)
        self.assertGreaterEqual(result['maxOwnedProcessGroups'], 2)
        self.assertGreaterEqual(result['maxOwnedProcesses'], 2)

    def test_separate_session_descendant_rss_stops_tree(self):
        child = 'import time; data=bytearray(80*1024*1024); time.sleep(30)'
        driver = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + '],start_new_session=True); time.sleep(30)'
        original = bounded.RSS_CAP
        try:
            # Test-only ceiling. No production CLI/env can lower or raise it.
            bounded.RSS_CAP = 40*1024*1024
            result = bounded.run_owned([sys.executable, '-c', driver],
                                       measure=lambda pid: self.sample(), interval=.01)
        finally:
            bounded.RSS_CAP = original
        self.assertEqual(result['status'], 'stopped')
        self.assertEqual(result['exitCode'], 137)
        self.assertGreater(result['peakOwnedRSSBytes'], 40*1024*1024)
        self.assertGreaterEqual(result['maxOwnedProcessGroups'], 2)

    def test_retained_pid_with_changed_birth_is_never_signalled(self):
        tree = object.__new__(bounded.ProcessTree)
        tree.owned = {123: (1, 2)}
        reused = bounded.BSDInfo()
        reused.seconds, reused.microseconds, reused.status = 3, 4, 2
        with mock.patch.object(bounded, 'process_info', return_value=reused), mock.patch.object(bounded.os, 'kill') as kill:
            tree.signal_owned(signal.SIGKILL)
            kill.assert_not_called()
            self.assertFalse(tree.running())

    def test_persistent_enumeration_failure_still_kills_retained_detached_child(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / 'detached-pid'
            child = 'import os,time; open(' + repr(str(pidfile)) + ',"w").write(str(os.getpid())); time.sleep(30)'
            driver = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + '],start_new_session=True); time.sleep(30)'
            original_sample = bounded.ProcessTree.sample
            def fail_after_discovery(tree):
                if len(tree.owned) >= 2:
                    raise RuntimeError('persistent ps outage')
                result = original_sample(tree)
                if len(tree.owned) >= 2:
                    raise RuntimeError('persistent ps outage')
                return result
            with mock.patch.object(bounded.ProcessTree, 'sample', fail_after_discovery):
                with self.assertRaisesRegex(RuntimeError, 'persistent ps outage'):
                    bounded.run_owned([sys.executable, '-c', driver], measure=lambda pid: self.sample(), interval=.01)
            if pidfile.exists():
                pid = int(pidfile.read_text())
                state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not state or state.startswith('Z'), 'retained detached child survived ps outage')

    def test_identity_unavailable_is_not_disappearance(self):
        tree = object.__new__(bounded.ProcessTree)
        tree.owned = {123: (1, 2)}
        with mock.patch.object(bounded, 'process_info', side_effect=bounded.ProcessIdentityUnavailable('telemetry offline')), mock.patch.object(bounded.os, 'kill') as kill:
            self.assertTrue(tree.running())
            tree.signal_owned(signal.SIGKILL)
            kill.assert_not_called()
        def missing(*args):
            bounded.ctypes.set_errno(errno.ESRCH)
            return 0
        def unavailable(*args):
            bounded.ctypes.set_errno(errno.EPERM)
            return 0
        with mock.patch.object(bounded.LIBPROC, 'proc_pidinfo', side_effect=missing):
            self.assertIsNone(bounded.process_info(123))
        with mock.patch.object(bounded.LIBPROC, 'proc_pidinfo', side_effect=unavailable):
            with self.assertRaises(bounded.ProcessIdentityUnavailable):
                bounded.process_info(123)

    def test_identity_outage_keeps_lock_until_telemetry_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            lockpath = Path(directory) / 'lock'
            offline = Path(directory) / 'offline'
            resume = Path(directory) / 'resume'
            pidfile = Path(directory) / 'child'
            child = 'import os,time; open(' + repr(str(pidfile)) + ',"w").write(str(os.getpid())); time.sleep(30)'
            driver = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + '],start_new_session=True); time.sleep(30)'
            code = "import importlib.util,os,fcntl,sys,pathlib\ns=importlib.util.spec_from_file_location('b'," + repr(str(Path(bounded.__file__))) + "); b=importlib.util.module_from_spec(s); s.loader.exec_module(b)\noffline=pathlib.Path(" + repr(str(offline)) + "); resume=pathlib.Path(" + repr(str(resume)) + ")\noriginal_info=b.process_info; original_sample=b.ProcessTree.sample\ndef info(pid):\n if offline.exists() and not resume.exists(): raise b.ProcessIdentityUnavailable('injected outage')\n return original_info(pid)\ndef sample(tree):\n result=original_sample(tree)\n if len(tree.owned)>=2: offline.touch()\n return result\nb.process_info=info; b.ProcessTree.sample=sample\nfd=os.open(" + repr(str(lockpath)) + ",os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(fd,fcntl.LOCK_EX)\nb.run_owned([sys.executable,'-c'," + repr(driver) + "],lock_fd=fd,measure=lambda pid: {'availableBytes':20*b.GIB,'rssBytes':0,'swapBytes':0})"
            wrapper = subprocess.Popen([sys.executable, '-c', code], start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not (offline.exists() and pidfile.exists()) and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(offline.exists() and pidfile.exists())
                os.kill(wrapper.pid, signal.SIGKILL)
                wrapper.wait()
                # Longer than normal TERM/KILL cleanup: unknown identities must
                # retain the guardian lock, even with the wrapper already dead.
                time.sleep(.7)
                attempt = lambda: subprocess.run(['/usr/bin/lockf', '-k', '-t', '0', str(lockpath), '/usr/bin/true'], capture_output=True).returncode
                self.assertNotEqual(attempt(), 0)
                resume.touch()
                deadline = time.monotonic() + 3
                while attempt() != 0 and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(attempt(), 0)
                state = subprocess.run(['/bin/ps', '-p', pidfile.read_text(), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                self.assertTrue(not state or state.startswith('Z'))
            finally:
                resume.touch()  # Never strand a guardian if an assertion fails.
                if wrapper.poll() is None:
                    os.kill(wrapper.pid, signal.SIGKILL)
                    wrapper.wait()

    def test_receipt_atomic_private_and_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'receipt.json'
            bounded.write_receipt(path, {'status': 'passed', 'peakOwnedRSSBytes': 123})
            self.assertEqual(json.loads(path.read_text())['peakOwnedRSSBytes'], 123)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
