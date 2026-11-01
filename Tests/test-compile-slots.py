#!/usr/bin/env python3
"""COS_COMPILE_SLOTS (compile-bounded.py and compile-guard.sh) with stand-in compilers: never runs Swift and never
touches the machine's real compile lock (each test points the lock at its own directory)."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bounded', HERE / 'compile-bounded.py')
bounded = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bounded)
G = bounded.GIB

HOLDER = r'''
import importlib.util, sys, time, pathlib
s = importlib.util.spec_from_file_location('b', sys.argv[1]); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
b.LOCK = sys.argv[2]
release = pathlib.Path(sys.argv[5])
try:
    fds, slot = b.acquire(int(sys.argv[3]), wait=float(sys.argv[4]), poll=.02)
except TimeoutError:
    print('timeout', flush=True); sys.exit(3)
print('got', slot, flush=True)
while not release.exists():
    time.sleep(.02)
'''

# A whole bounded compile (main) against a stand-in swiftc, the lock moved into the test directory.
MAIN = r'''
import importlib.util, subprocess, sys
s = importlib.util.spec_from_file_location('b', sys.argv[1]); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
b.LOCK = sys.argv[2]
# Hermetic: count only this test's stand-in frontends, never a real compile elsewhere on the machine.
mine = b.frontend_rss
def frontend_rss(pgid=None, rows=None):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pgid=,rss=,comm='], text=True).splitlines()
    return mine(pgid, [r for r in rows if sys.argv[2].rsplit('/', 1)[0] in r])
b.frontend_rss = frontend_rss
sys.argv = ['compile-bounded.py', '--receipt', sys.argv[3], '--', *sys.argv[4:]]
sys.exit(b.main())
'''

FAKE_SWIFTC = r'''#!/bin/sh
for a in "$@"; do [ "$a" = -driver-print-jobs ] && { echo "/x/swift-frontend -frontend -c -primary-file a.swift"; exit 0; }; done
echo "start $$ $(/bin/date +%s.%N 2>/dev/null || /bin/date +%s)" >> "$FAKE_LOG"
"$FAKE_FRONTEND" "${FAKE_SECONDS:-1}"
echo "end $$" >> "$FAKE_LOG"
'''


def available():
    return bounded.telemetry()['availableBytes']


class SlotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cos-slots-', dir='/tmp')
        self.dir = Path(self.temp.name)
        self.lock = str(self.dir / 'lock')
        self.procs = []

    def tearDown(self):
        (self.dir / 'release').touch()
        for p in self.procs:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        self.temp.cleanup()

    def holder(self, slots, wait=5.0, release='release'):
        p = subprocess.Popen([sys.executable, '-c', HOLDER, bounded.__file__, self.lock, str(slots), str(wait),
                              str(self.dir / release)], stdout=subprocess.PIPE, text=True)
        self.procs.append(p)
        return p

    def lockf(self, path, timeout=0):
        return subprocess.run(['/usr/bin/lockf', '-k', '-t', str(timeout), path, '/usr/bin/true'], capture_output=True).returncode

    def test_two_slots_run_two_compiles_and_a_third_waits(self):
        a, b = self.holder(2, release='ra'), self.holder(2, release='rb')
        got = sorted(a.stdout.readline().split()[1:] + b.stdout.readline().split()[1:])
        self.assertEqual(got, ['0', '1'])  # both at once, one slot each
        c = self.holder(2, wait=5.0)
        time.sleep(.6)
        self.assertIsNone(c.poll())  # still waiting: no third slot
        (self.dir / 'ra').touch()
        self.assertTrue(c.stdout.readline().startswith('got'))
        d = self.holder(2, wait=.3, release='rd')
        self.assertEqual(d.stdout.readline().strip(), 'timeout')
        (self.dir / 'rb').touch()

    def test_exclusive_waits_for_every_slot(self):
        a, b = self.holder(3, release='ra'), self.holder(3, release='rb')
        a.stdout.readline(); b.stdout.readline()
        self.assertNotEqual(self.lockf(self.lock), 0)  # an exclusive user (lockf = the large profile, SLOTS=1, old checkouts)
        (self.dir / 'ra').touch(); a.wait()
        self.assertNotEqual(self.lockf(self.lock), 0)  # one slot still busy
        (self.dir / 'rb').touch(); b.wait()
        self.assertEqual(self.lockf(self.lock), 0)

    def test_slotted_compile_never_starts_beside_an_exclusive_one(self):
        lockf = subprocess.Popen(['/usr/bin/lockf', '-k', self.lock, '/bin/sleep', '1.5'])
        self.procs.append(lockf)
        time.sleep(.2)
        started = time.monotonic()
        a = self.holder(3)
        self.assertTrue(a.stdout.readline().startswith('got'))
        self.assertGreater(time.monotonic() - started, 1.0)

    def test_large_profile_is_exclusive_and_gated(self):
        a = self.holder(3, release='ra')
        a.stdout.readline()
        marker = self.dir / 'large-ran'
        env = dict(os.environ, COS_COMPILE_LOCK=self.lock, COS_COMPILE_PROFILE='large', COS_COMPILE_MIN_FREE_GB='0')
        large = subprocess.Popen(['/bin/zsh', str(HERE / 'compile-guard.sh'), '/usr/bin/touch', str(marker)], env=env)
        self.procs.append(large)
        time.sleep(.8)
        self.assertFalse(marker.exists())  # waits for the slotted compile
        late = self.holder(3, wait=.5, release='rl')
        self.assertEqual(late.stdout.readline().strip(), 'timeout')  # the waiting exclusive holds the gate: no starvation
        (self.dir / 'ra').touch()
        self.assertEqual(large.wait(timeout=10), 0)
        self.assertTrue(marker.exists())
        self.assertTrue(self.holder(3, wait=2, release='r2').stdout.readline().startswith('got'))

    def test_one_slot_is_todays_single_lock(self):
        self.assertEqual(bounded.slot_count({}), 1)
        self.assertEqual(bounded.slot_count({'COS_COMPILE_SLOTS': '1'}), 1)
        for bad in ('0', '9', '2.5', 'x', '-1', '12'):
            with self.assertRaises(ValueError):
                bounded.slot_count({'COS_COMPILE_SLOTS': bad})
        a = self.holder(1, release='ra')
        self.assertEqual(a.stdout.readline().strip(), 'got None')
        # 2026-10-31 (A6): SLOTS=1 waits behind the gate like the large profile, so the gate file exists; still no slot or owner files.
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ['lock', 'lock.gate'])
        self.assertNotEqual(self.lockf(self.lock), 0)
        b = self.holder(1, wait=.3, release='rb')
        self.assertEqual(b.stdout.readline().strip(), 'timeout')  # one at a time, as before
        source = self.dir / 'a.swift'; source.write_text('')
        base = ['swiftc', str(source), '-o', str(self.dir / 'app')]
        with self.assertRaises(ValueError):
            bounded.normalize(base, {'COS_COMPILE_MAX_TOTAL_GB': '24'})
        with self.assertRaises(ValueError):
            bounded.normalize(base, {'COS_COMPILE_MAX_TOTAL_GB': '24', 'COS_COMPILE_SLOTS': '1'})
        bounded.normalize(base, {'COS_COMPILE_MAX_TOTAL_GB': '24', 'COS_COMPILE_SLOTS': '3'})
        for key in ('COS_COMPILE_LOCK', 'COS_COMPILE_MIN_FREE_GB', 'COS_COMPILE_MAX_FRONTEND_GB', 'SWIFT_EXEC'):
            with self.assertRaises(ValueError):
                bounded.normalize(base, {key: '1', 'COS_COMPILE_SLOTS': '3'})
        self.assertEqual(bounded.total_cap_bytes({'COS_COMPILE_MAX_TOTAL_GB': '24'}), 24 * G)
        for bad in ('0', '-3', 'lots'):
            with self.assertRaises(ValueError):
                bounded.total_cap_bytes({'COS_COMPILE_MAX_TOTAL_GB': bad})

    def test_guard_routes_swiftc_to_bounded_only_when_slotted(self):
        # The bounded lane refuses this environment (a free-memory override) before it touches any lock, which proves
        # which lane ran without ever using the machine's real lock.
        fake = self.dir / 'bin'; fake.mkdir()
        (fake / 'swiftc').write_text('#!/bin/sh\ntouch "$FAKE_RAN"\n'); (fake / 'swiftc').chmod(0o755)
        ran = self.dir / 'ran'
        env = dict(os.environ, PATH=f'{fake}:{os.environ["PATH"]}', COS_COMPILE_MIN_FREE_GB='0', FAKE_RAN=str(ran),
                   COS_COMPILE_RECEIPT_DIR=str(self.dir / 'receipts'))
        env.pop('COS_COMPILE_SLOTS', None)
        command = ['/bin/zsh', str(HERE / 'compile-guard.sh'), 'swiftc', '-bogus']
        one = subprocess.run(command, env=dict(env, COS_COMPILE_LOCK=self.lock), capture_output=True, text=True)
        self.assertEqual(one.returncode, 0)
        self.assertTrue(ran.exists())  # SLOTS=1 with free memory: the large lane, as today
        ran.unlink()
        three = subprocess.run(command, env=dict(env, COS_COMPILE_SLOTS='3'), capture_output=True, text=True)
        self.assertEqual(three.returncode, 70)
        self.assertIn('compile-bounded: infrastructure-error', three.stderr)  # refused before any lock
        self.assertFalse(ran.exists())
        bad = subprocess.run(command, env=dict(env, COS_COMPILE_SLOTS='9'), capture_output=True, text=True)
        self.assertEqual(bad.returncode, 2)

    def test_switch_stops_only_the_newest(self):
        class P:
            pid = 50
        owners = [{'pid': 1, 'acquiredNs': 100}, {'pid': 2, 'acquiredNs': 200}]
        rss = lambda over, mine: (lambda pgid: (over, mine))
        cap = 24 * G
        newest = bounded.total_switch(cap, 2, owners=lambda: owners, rss=rss(25 * G, 8 * G))
        older = bounded.total_switch(cap, 1, owners=lambda: owners, rss=rss(25 * G, 8 * G))
        self.assertIn('newest', newest(P()))
        self.assertIsNone(older(P()))
        self.assertIsNone(bounded.total_switch(cap, 2, owners=lambda: owners, rss=rss(24 * G, 8 * G))(P()))
        self.assertIsNone(bounded.total_switch(cap, 2, owners=lambda: owners, rss=rss(25 * G, 25 * G))(P()))  # alone
        self.assertIsNone(bounded.total_switch(cap, 2, owners=lambda: [], rss=rss(25 * G, 8 * G))(P()))
        rows = ['50 1048576 /x/swift-frontend', '51 2097152 swift-frontend', '50 999 /bin/zsh', 'junk']
        self.assertEqual(bounded.frontend_rss(50, rows), (3 * G, G))

    def compile_main(self, name, seconds, cap):
        source = self.dir / 'a.swift'; source.write_text('')
        env = dict(os.environ, COS_COMPILE_SLOTS='2', COS_COMPILE_MAX_TOTAL_GB=cap, FAKE_LOG=str(self.dir / 'log'),
                   FAKE_FRONTEND=str(self.dir / 'swift-frontend'), FAKE_SECONDS=str(seconds),
                   PATH=f'{self.dir / "bin"}:{os.environ["PATH"]}')
        p = subprocess.Popen([sys.executable, '-c', MAIN, bounded.__file__, self.lock, str(self.dir / (name + '.json')),
                              'swiftc', str(source), '-o', str(self.dir / name)], env=env, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        return p

    def test_one_slot_bounded_compile_is_unchanged_end_to_end(self):
        if available() < bounded.START_FREE + 2 * G:
            self.skipTest('the bounded lane needs 16 GiB free to start')
        (self.dir / 'bin').mkdir()
        (self.dir / 'bin/swiftc').write_text(FAKE_SWIFTC); (self.dir / 'bin/swiftc').chmod(0o755)
        os.symlink('/bin/sleep', self.dir / 'swift-frontend')
        (self.dir / 'a.swift').write_text('')
        shapes = {}
        for name, value in (('unset', None), ('one', '1')):
            env = dict(os.environ, FAKE_LOG=str(self.dir / 'log'), FAKE_FRONTEND=str(self.dir / 'swift-frontend'),
                       FAKE_SECONDS='0.2', PATH=f'{self.dir / "bin"}:{os.environ["PATH"]}')
            env.pop('COS_COMPILE_SLOTS', None); env.pop('COS_COMPILE_MAX_TOTAL_GB', None)
            if value:
                env['COS_COMPILE_SLOTS'] = value
            r = subprocess.run([sys.executable, '-c', MAIN, bounded.__file__, self.lock, str(self.dir / (name + '.json')),
                                'swiftc', str(self.dir / 'a.swift'), '-o', str(self.dir / name)],
                               env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stderr)
            receipt = json.loads((self.dir / (name + '.json')).read_text())
            self.assertNotIn('slot', receipt)
            shapes[name] = (sorted(receipt), receipt['status'], receipt['policy'], r.stderr.replace(name, 'X'))
            self.assertEqual(sorted(p.name for p in self.dir.glob('lock*')), ['lock', 'lock.gate'])  # no slot or owner files
        self.assertEqual(shapes['unset'], shapes['one'])

    def test_total_switch_end_to_end_stops_the_newest_compile_only(self):
        if available() < bounded.START_FREE + 2 * G:
            self.skipTest('the bounded lane needs 16 GiB free to start')
        (self.dir / 'bin').mkdir()
        (self.dir / 'bin/swiftc').write_text(FAKE_SWIFTC); (self.dir / 'bin/swiftc').chmod(0o755)
        os.symlink('/bin/sleep', self.dir / 'swift-frontend')  # ps reports it as .../swift-frontend (a copy is killed by AMFI)
        older = self.compile_main('older', 4, '0.0001')
        deadline = time.monotonic() + 5
        while not (self.dir / 'log').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        time.sleep(.5)
        newer = self.compile_main('newer', 4, '0.0001')
        newer_err = newer.communicate(timeout=20)[1]
        older_err = older.communicate(timeout=20)[1]
        self.assertEqual(newer.returncode, 137, newer_err)
        self.assertIn('STOPPED (slot', newer_err)
        self.assertIn('newest compile', newer_err)
        self.assertEqual(older.returncode, 0, older_err)  # left running; alone it answers to its own cap
        receipt = json.loads((self.dir / 'newer.json').read_text())
        self.assertEqual(receipt['status'], 'stopped')
        self.assertEqual(json.loads((self.dir / 'older.json').read_text())['status'], 'passed')
        self.assertEqual([p.name for p in self.dir.glob('lock.slot*.owner')], [])  # owners released

    # ---- A6 (2026-10-31): SLOTS=1 waits behind the gate for up to SLOT_WAIT, with progress lines ----
    def test_one_slot_waits_behind_the_gate_so_slotted_compiles_cannot_starve_it(self):
        a = self.holder(3, release='ra')
        self.assertTrue(a.stdout.readline().startswith('got'))  # a slotted compile holds LOCK shared
        waiter = self.holder(1, wait=20, release='rw')
        time.sleep(.6)
        self.assertIsNone(waiter.poll())  # SLOTS=1 needs LOCK exclusive: it waits
        late = self.holder(3, wait=.6, release='rl')
        self.assertEqual(late.stdout.readline().strip(), 'timeout')  # the waiter holds the gate: no new slotted compile jumps ahead
        (self.dir / 'ra').touch(); a.wait()
        self.assertEqual(waiter.stdout.readline().strip(), 'got None')
        self.assertEqual(self.lockf(self.lock + '.gate'), 0)  # it let go of the gate once it held LOCK: the compile holds just LOCK
        self.assertNotEqual(self.lockf(self.lock), 0)
        self.assertEqual(self.holder(3, wait=.5, release='r2').stdout.readline().strip(), 'timeout')  # LOCK exclusive keeps slotted out
        (self.dir / 'rw').touch(); waiter.wait()
        self.assertTrue(self.holder(3, wait=3, release='r3').stdout.readline().startswith('got'))

    def test_one_slot_waits_slot_wait_not_120_seconds_and_says_so_every_minute(self):
        class FakeClock:  # no real waiting: a sleep just advances the clock; everything else is the real time module
            now = 0.0
            def monotonic(self): return self.now
            def sleep(self, seconds): self.now += seconds
            def __getattr__(self, name): return getattr(time, name)
        clock = FakeClock()
        self.assertEqual(bounded.SLOT_WAIT, 1800)
        self.assertEqual(bounded.PROGRESS_SECONDS, 60)
        busy = os.open(self.lock, os.O_CREAT | os.O_RDWR, 0o600)
        bounded.fcntl.flock(busy, bounded.fcntl.LOCK_EX)  # another compile holds the lock the whole time
        try:
            err = io.StringIO()
            with mock.patch.object(bounded, 'LOCK', self.lock), mock.patch.object(bounded, 'time', clock), contextlib.redirect_stderr(err):
                with self.assertRaises(TimeoutError) as caught:
                    bounded.acquire(1)
            self.assertIn('shared compile lock busy after 1800 seconds', str(caught.exception))  # the phrase other lanes grep for
            self.assertGreaterEqual(clock.now, 1800)
            self.assertLess(clock.now, 1801)  # it did give up, at SLOT_WAIT
            lines = [l for l in err.getvalue().splitlines() if l]
            self.assertTrue(all(l.startswith('compile-bounded: waiting for the shared compile lock (') for l in lines), lines)
            self.assertIn('(60 s of 1800 s)', lines[0])
            self.assertTrue(28 <= len(lines) <= 30, len(lines))  # about one a minute, not one a poll and not none
            # An explicit wait still wins, and a short wait is silent.
            clock.now = 0.0
            err = io.StringIO()
            with mock.patch.object(bounded, 'LOCK', self.lock), mock.patch.object(bounded, 'time', clock), contextlib.redirect_stderr(err):
                with self.assertRaises(TimeoutError) as caught:
                    bounded.acquire(1, wait=5)
            self.assertIn('busy after 5 seconds', str(caught.exception))
            self.assertLess(clock.now, 6)
            self.assertEqual(err.getvalue(), '')
            # A timeout leaves nothing held: the gate is free for the next compile.
            self.assertEqual(self.lockf(self.lock + '.gate'), 0)
        finally:
            os.close(busy)

    # ---- A5 (2026-10-31): the profile a release or a stop is pinned to ----
    def test_build_release_pins_every_guarded_compile_to_the_bounded_lane(self):
        # build-release.sh run for real in a scratch root whose guard and pre-step scripts only record the profile they were
        # started under. The profile a script exports is what the real compile-guard.sh resolves (next test).
        script = HERE.parent / 'scripts' / 'build-release.sh'
        for ambient in (None, 'large', 'auto'):  # nothing set, the large profile asked for, auto (the memory-dependent default)
            root = self.dir / ('root-' + str(ambient))
            (root / 'scripts').mkdir(parents=True); (root / 'Tests').mkdir(); (root / 'Resources').mkdir()
            shutil.copy(script, root / 'scripts' / 'build-release.sh')
            (root / 'Resources' / 'Info.plist').write_text(
                '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key>'
                '<string>0.0.1</string></dict></plist>')
            record = root / 'record'
            stub = '#!/bin/zsh\nprint -r -- "${0:t} ${COS_COMPILE_PROFILE-UNSET}" >> "$RECORD"\n'
            for name in ('run-work-board-perf.sh', 'run-control-instance.sh', 'compile-guard.sh'):
                (root / 'Tests' / name).write_text(stub); (root / 'Tests' / name).chmod(0o755)
            (root / 'Tests' / 'desktop-safety-check.py').write_text('')
            env = {k: v for k, v in os.environ.items() if not k.startswith('COS_')}
            env.update(RECORD=str(record), COS_BUILD_DIST_DIR=str(root / 'dist'))
            if ambient:
                env['COS_COMPILE_PROFILE'] = ambient
            r = subprocess.run(['/bin/zsh', str(root / 'scripts' / 'build-release.sh')], env=env, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(r.returncode, 0)  # the scratch root has no app resources: it stops right after the two compiles
            lines = record.read_text().splitlines()
            self.assertEqual(sorted(l.split()[0] for l in lines),
                             ['compile-guard.sh', 'compile-guard.sh', 'run-control-instance.sh', 'run-work-board-perf.sh'], (ambient, lines))
            self.assertEqual({l.split()[1] for l in lines}, {'bounded'}, (ambient, lines))  # the pre-steps and both compiles

    def test_bounded_profile_outranks_the_free_memory_route_in_the_guard(self):
        # With SLOTS=1 and plenty of free memory (MIN_FREE 0), auto sends swiftc to the large profile. COS_COMPILE_PROFILE=bounded
        # must send it to the bounded lane instead. That lane refuses COS_COMPILE_MIN_FREE_GB before it touches any lock, which
        # proves the lane without using the machine's real lock.
        fake = self.dir / 'bin'; fake.mkdir()
        (fake / 'swiftc').write_text('#!/bin/sh\ntouch "$FAKE_RAN"\n'); (fake / 'swiftc').chmod(0o755)
        ran = self.dir / 'ran'
        env = dict(os.environ, PATH=f'{fake}:{os.environ["PATH"]}', COS_COMPILE_MIN_FREE_GB='0', FAKE_RAN=str(ran),
                   COS_COMPILE_RECEIPT_DIR=str(self.dir / 'receipts'), COS_COMPILE_LOCK=self.lock)
        env.pop('COS_COMPILE_SLOTS', None); env.pop('COS_COMPILE_GUARD_HELD', None)
        command = ['/bin/zsh', str(HERE / 'compile-guard.sh'), 'swiftc', '-bogus']
        auto = subprocess.run(command, env=dict(env, COS_COMPILE_PROFILE='auto'), capture_output=True, text=True)
        self.assertEqual(auto.returncode, 0)
        self.assertTrue(ran.exists())  # the large lane ran the stand-in
        ran.unlink()
        pinned = subprocess.run(command, env=dict(env, COS_COMPILE_PROFILE='bounded'), capture_output=True, text=True)
        self.assertEqual(pinned.returncode, 70)
        self.assertIn('compile-bounded: infrastructure-error', pinned.stderr)
        self.assertFalse(ran.exists())

    def test_large_profile_stop_kills_only_its_own_process_tree(self):
        fe = self.dir / 'swift-frontend'
        os.symlink('/bin/sleep', fe)  # ps reports it as .../swift-frontend (a copy is killed by AMFI)
        bin_dir = self.dir / 'bin'; bin_dir.mkdir()
        # A stand-in ps: the real one, except that once TRIP exists every swift-frontend row reports an absurd RSS, which is the
        # thing the watchdog stops on. It keeps the test exact on a machine that has real compiles running.
        (bin_dir / 'ps').write_text('#!/bin/sh\nif [ -e "$TRIP" ] && [ "$2" = "pid=,rss=,comm=" ]; then /bin/ps "$@" | '
                                    "/usr/bin/awk '$3 ~ /swift-frontend$/ { $2 = 99999999999 } { print }'; else exec /bin/ps \"$@\"; fi\n")
        (bin_dir / 'ps').chmod(0o755)  # without this the shell skips it and the guard measures with the real ps, and never stops
        # command -> sh -> sh -> swift-frontend: three generations below the command the guard runs.
        pids = self.dir / 'pids'; pids.mkdir()
        scripts = {'cmd.sh': '/bin/sh "$DIR/inner1.sh" &\necho $! > "$PIDS/inner1"\nwait\n',
                   'inner1.sh': '/bin/sh "$DIR/inner2.sh" &\necho $! > "$PIDS/inner2"\nwait\n',
                   'inner2.sh': '"$FE" 60 &\necho $! > "$PIDS/frontend"\nwait\n'}
        for name, body in scripts.items():
            (self.dir / name).write_text('#!/bin/sh\n' + body)
        env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', COS_COMPILE_LOCK=self.lock, COS_COMPILE_PROFILE='large',
                   COS_COMPILE_MIN_FREE_GB='0', COS_COMPILE_MAX_FRONTEND_GB='4096', COS_COMPILE_MAX_TOTAL_GB='1000000',
                   TRIP=str(self.dir / 'trip'), FE=str(fe), DIR=str(self.dir), PIDS=str(pids),
                   COS_TEST_FRONTEND_DIR=str(self.dir))  # read only by the pattern-kill mutant: scopes it to THIS test's stand-ins
        def alive(pid):
            state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
            return bool(state) and not state.startswith('Z')
        decoy = subprocess.Popen([str(fe), '60'])  # a swift-frontend that is NOT in the guarded command's tree
        guard = subprocess.Popen(['/bin/zsh', str(HERE / 'compile-guard.sh'), '/bin/sh', str(self.dir / 'cmd.sh')], env=env,
                                 stderr=subprocess.PIPE, text=True)
        inside = {}
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not all((pids / n).exists() and (pids / n).read_text().strip() for n in ('inner1', 'inner2', 'frontend')):
                time.sleep(.05)
            inside = {n: int((pids / n).read_text()) for n in ('inner1', 'inner2', 'frontend')}
            self.assertTrue(all(alive(p) for p in inside.values()), inside)
            self.assertTrue(alive(decoy.pid))
            (self.dir / 'trip').touch()  # the watchdog's next sample sees an oversized swift-frontend and stops the run
            err = guard.communicate(timeout=30)[1]
            self.assertEqual(guard.returncode, 137, err)
            self.assertIn('compile-guard: STOPPED: a swift-frontend passed', err)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and any(alive(p) for p in inside.values()):
                time.sleep(.05)
            self.assertEqual({n: alive(p) for n, p in inside.items()}, {'inner1': False, 'inner2': False, 'frontend': False})
            self.assertIsNone(decoy.poll())  # the swift-frontend outside the tree is untouched
            self.assertTrue(alive(decoy.pid))
        finally:
            decoy.kill()  # Popen children this test started
            guard.kill()
            for pid in inside.values():
                # A leftover stand-in (a failed assertion above). Signal it only if its command line is still this test's own.
                command = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
                if str(self.dir) in command:
                    os.kill(pid, 9)
            decoy.wait(timeout=5)
            guard.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
