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


def clean_env(**extra):
    """This process's environment minus everything that steers the compile guard, then `extra`. Run.sh exports
    COS_COMPILE_PROFILE=bounded and COS_TEST_KIT_*; a guard test that inherited them (review 1, 2026-10-31) failed 70 != 0. Every
    test that drives compile-guard.sh or compile-bounded.py builds its environment here and states the profile it means."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(('COS_COMPILE', 'COS_TEST_KIT', 'SWIFT_'))}
    env.update(extra)
    return env

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


# The real ps, except for the guard's own sampling call: a pid listed in $TRIP reports an absurd RSS, and a pid listed in $REUSE
# reports a different start time (as if another process had been given that pid). Everything else passes straight through.
PS_STANDIN = r"""#!/bin/sh
if [ "$2" = "pid=,ppid=,rss=,lstart=,comm=" ]; then
  /bin/ps "$@" | /usr/bin/awk -v t="$TRIP" -v r="$REUSE" '
    BEGIN { while ((getline l < t) > 0) big[l] = 1; while ((getline l < r) > 0) re[l] = 1 }
    ($1 in big) { $3 = 99999999999 }
    ($1 in re) { $4 = "Mon"; $5 = "Jan"; $6 = "1"; $7 = "00:00:00"; $8 = "2001" }
    { print }'
else
  exec /bin/ps "$@"
fi
"""

# The real compile-bounded.py with its lock moved into the test directory and the compiler run stubbed, so a receipt can be
# produced THROUGH compile-guard.sh without the machine's lock or a 16 GiB floor. Run by /usr/bin/python3, as in production.
LAUNCHER = r"""
import importlib.util, sys
s = importlib.util.spec_from_file_location('b', @@REAL@@); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
b.LOCK = @@LOCK@@
def fake_run_owned(command, **kwargs):
    if '-driver-print-jobs' in command:
        kwargs['stdout'].write('/x/swift-frontend -frontend -c -primary-file a.swift\n')
        return {'status': 'passed', 'exitCode': 0}
    return {'status': 'passed', 'exitCode': 0, 'peakOwnedRSSBytes': 1}
b.run_owned = fake_run_owned
sys.exit(b.main())
"""


def available():
    return bounded.telemetry()['availableBytes']


class Base(unittest.TestCase):
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
        self.sweep()
        for p in (getattr(self, 'decoy', None), getattr(self, 'guard', None)):
            if p is not None:
                p.wait(timeout=10)
        self.temp.cleanup()

    def sweep(self):
        # Anything still carrying THIS test's unique temp directory in its command line is a stand-in this test started.
        out = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
        for line in out.splitlines():
            pid, _, command = line.strip().partition(' ')
            if str(self.dir) in command and int(pid) != os.getpid():
                try:
                    os.kill(int(pid), 9)
                except OSError:
                    pass

    def holder(self, slots, wait=5.0, release='release'):
        p = subprocess.Popen([sys.executable, '-c', HOLDER, bounded.__file__, self.lock, str(slots), str(wait),
                              str(self.dir / release)], stdout=subprocess.PIPE, text=True)
        self.procs.append(p)
        return p

    def lockf(self, path, timeout=0):
        return subprocess.run(['/usr/bin/lockf', '-k', '-t', str(timeout), path, '/usr/bin/true'], capture_output=True).returncode


class SlotTests(Base):
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
        env = clean_env(COS_COMPILE_LOCK=self.lock, COS_COMPILE_PROFILE='large', COS_COMPILE_MIN_FREE_GB='0')
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
        # auto is the profile this test means (run.sh exports bounded; clean_env drops that and every other steering variable).
        env = clean_env(PATH=f'{fake}:{os.environ["PATH"]}', COS_COMPILE_PROFILE='auto', COS_COMPILE_MIN_FREE_GB='0', FAKE_RAN=str(ran),
                        COS_COMPILE_RECEIPT_DIR=str(self.dir / 'receipts'))
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
        env = clean_env(COS_COMPILE_SLOTS='2', COS_COMPILE_MAX_TOTAL_GB=cap, FAKE_LOG=str(self.dir / 'log'),
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
            env = clean_env(FAKE_LOG=str(self.dir / 'log'), FAKE_FRONTEND=str(self.dir / 'swift-frontend'),
                            FAKE_SECONDS='0.2', PATH=f'{self.dir / "bin"}:{os.environ["PATH"]}')
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
        # build-release.sh run for real in a scratch root whose guard and pre-step scripts only record the environment they were
        # started under. The profile a script exports is what the real compile-guard.sh resolves (the test after next).
        # COS_TEST_KIT_PERSIST=0 as well (review 1, note 10): a kit store inherited from a suite run must not feed a release's gate lanes.
        script = HERE.parent / 'scripts' / 'build-release.sh'
        for ambient in ((None, None), ('large', '1'), ('auto', '1')):  # nothing set / the large profile + a persistent store / auto + a store
            root = self.dir / ('root-' + str(ambient[0]))
            (root / 'scripts').mkdir(parents=True); (root / 'Tests').mkdir(); (root / 'Resources').mkdir()
            shutil.copy(script, root / 'scripts' / 'build-release.sh')
            (root / 'Resources' / 'Info.plist').write_text(
                '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key>'
                '<string>0.0.1</string></dict></plist>')
            record = root / 'record'
            stub = '#!/bin/zsh\nprint -r -- "${0:t} ${COS_COMPILE_PROFILE-UNSET} ${COS_TEST_KIT_PERSIST-UNSET}" >> "$RECORD"\n'
            for name in ('run-work-board-perf.sh', 'run-control-instance.sh', 'compile-guard.sh'):
                (root / 'Tests' / name).write_text(stub); (root / 'Tests' / name).chmod(0o755)
            (root / 'Tests' / 'desktop-safety-check.py').write_text('')
            env = {k: v for k, v in os.environ.items() if not k.startswith('COS_')}
            env.update(RECORD=str(record), COS_BUILD_DIST_DIR=str(root / 'dist'))
            if ambient[0]:
                env['COS_COMPILE_PROFILE'] = ambient[0]
            if ambient[1]:
                env['COS_TEST_KIT_PERSIST'] = ambient[1]
            r = subprocess.run(['/bin/zsh', str(root / 'scripts' / 'build-release.sh')], env=env, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(r.returncode, 0)  # the scratch root has no app resources: it stops right after the two compiles
            lines = record.read_text().splitlines()
            self.assertEqual(sorted(l.split()[0] for l in lines),
                             ['compile-guard.sh', 'compile-guard.sh', 'run-control-instance.sh', 'run-work-board-perf.sh'], (ambient, lines))
            self.assertEqual({l.split()[1] for l in lines}, {'bounded'}, (ambient, lines))  # the pre-steps and both compiles
            self.assertEqual({l.split()[2] for l in lines}, {'0'}, (ambient, lines))  # and none of them can read a persistent kit store

    def test_bounded_profile_outranks_the_free_memory_route_in_the_guard(self):
        # With SLOTS=1 and plenty of free memory (MIN_FREE 0), auto sends swiftc to the large profile. COS_COMPILE_PROFILE=bounded
        # must send it to the bounded lane instead. That lane refuses COS_COMPILE_MIN_FREE_GB before it touches any lock, which
        # proves the lane without using the machine's real lock.
        fake = self.dir / 'bin'; fake.mkdir()
        (fake / 'swiftc').write_text('#!/bin/sh\ntouch "$FAKE_RAN"\n'); (fake / 'swiftc').chmod(0o755)
        ran = self.dir / 'ran'
        env = clean_env(PATH=f'{fake}:{os.environ["PATH"]}', COS_COMPILE_MIN_FREE_GB='0', FAKE_RAN=str(ran),
                        COS_COMPILE_RECEIPT_DIR=str(self.dir / 'receipts'), COS_COMPILE_LOCK=self.lock)
        command = ['/bin/zsh', str(HERE / 'compile-guard.sh'), 'swiftc', '-bogus']
        auto = subprocess.run(command, env=dict(env, COS_COMPILE_PROFILE='auto'), capture_output=True, text=True)
        self.assertEqual(auto.returncode, 0)
        self.assertTrue(ran.exists())  # the large lane ran the stand-in
        ran.unlink()
        pinned = subprocess.run(command, env=dict(env, COS_COMPILE_PROFILE='bounded'), capture_output=True, text=True)
        self.assertEqual(pinned.returncode, 70)
        self.assertIn('compile-bounded: infrastructure-error', pinned.stderr)
        self.assertFalse(ran.exists())

    def test_a_receipt_produced_through_the_guard_records_one_job(self):
        # compile-guard.sh run for real, over a scratch copy of Tests/ whose compile-bounded.py is LAUNCHER (the real one, lock and
        # compiler stubbed). The guard's own exec line is under test: it must never pass --jobs, so suite and release compiles stay at 1.
        tests = self.dir / 'scratch-tests'; tests.mkdir()
        shutil.copy(HERE / 'compile-guard.sh', tests / 'compile-guard.sh')
        (tests / 'compile-bounded.py').write_text(LAUNCHER.replace('@@REAL@@', repr(str(HERE / 'compile-bounded.py'))).replace('@@LOCK@@', repr(self.lock)))
        fake = self.dir / 'bin'; fake.mkdir()
        (fake / 'swiftc').write_text('#!/bin/sh\nexit 99\n'); (fake / 'swiftc').chmod(0o755)  # resolved by shutil.which, never run
        source = self.dir / 'a.swift'; source.write_text('')
        for profile, slots in (('bounded', None), ('auto', '3')):  # both ways the guard reaches the bounded lane
            receipts = self.dir / ('receipts-' + profile)
            env = clean_env(PATH=f'{fake}:{os.environ["PATH"]}', COS_COMPILE_PROFILE=profile, COS_COMPILE_RECEIPT_DIR=str(receipts))
            if slots:
                env['COS_COMPILE_SLOTS'] = slots
            r = subprocess.run(['/bin/zsh', str(tests / 'compile-guard.sh'), 'swiftc', str(source), '-o', str(self.dir / 'app')],
                               env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            made = list(receipts.glob('compile.*'))
            self.assertEqual(len(made), 1, made)
            receipt = json.loads(made[0].read_text())
            self.assertEqual((receipt['profile'], receipt['jobs'], receipt['status']), ('bounded', 1, 'passed'), profile)


class WatchdogTests(Base):
    """The large-profile watchdog of compile-guard.sh, run for real over stand-in processes (no Swift, no real lock)."""
    # ---- the large-profile watchdog (compile-guard.sh) over stand-in processes -------------------------------------------
    def alive(self, pid):
        state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith('Z')

    def start_guard(self, scripts, **env_extra):
        """compile-guard.sh on the large profile over `scripts` (cmd.sh is the guarded command). A decoy swift-frontend runs OUTSIDE
        the command's tree. PS_STANDIN lets a test make a pid look huge or reused, on cue (files trip and reuse, one pid a line)."""
        self.fe = self.dir / 'swift-frontend'
        os.symlink('/bin/sleep', self.fe)  # ps reports .../swift-frontend (a copy is killed by AMFI)
        os.symlink('/bin/sleep', self.dir / 'marker-sleep')
        bin_dir = self.dir / 'bin'; bin_dir.mkdir()
        (bin_dir / 'ps').write_text(PS_STANDIN)
        (bin_dir / 'ps').chmod(0o755)  # without this the shell skips it and the guard samples with the real ps
        self.pids = self.dir / 'pids'; self.pids.mkdir()
        for name, body in scripts.items():
            (self.dir / name).write_text('#!/bin/sh\n' + body)
        (self.dir / 'trip').touch(); (self.dir / 'reuse').touch()
        env = clean_env(PATH=f'{bin_dir}:{os.environ["PATH"]}', COS_COMPILE_LOCK=self.lock, COS_COMPILE_PROFILE='large',
                        COS_COMPILE_MIN_FREE_GB='0', COS_COMPILE_MAX_FRONTEND_GB='4096', COS_COMPILE_MAX_TOTAL_GB='1000000',
                        TRIP=str(self.dir / 'trip'), REUSE=str(self.dir / 'reuse'), FE=str(self.fe), MARK=str(self.dir / 'marker-sleep'),
                        DIR=str(self.dir), PIDS=str(self.pids),
                        COS_TEST_FRONTEND_DIR=str(self.dir))  # read only by the pattern-kill mutant: scopes it to THIS test's stand-ins
        env.update(env_extra)
        self.guard_err = self.dir / 'guard.err'
        self.decoy = subprocess.Popen([str(self.fe), '600'])  # a swift-frontend that is NOT in the guarded command's tree
        with open(self.guard_err, 'w') as err:
            self.guard = subprocess.Popen(['/bin/zsh', str(HERE / 'compile-guard.sh'), '/bin/sh', str(self.dir / 'cmd.sh')], env=env, stderr=err)

    def pid_files(self, *names, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if all((self.pids / n).exists() and (self.pids / n).read_text().strip() for n in names):
                return {n: int((self.pids / n).read_text()) for n in names}
            time.sleep(.05)
        self.fail('the stand-in processes never started: ' + ', '.join(names))

    def mark(self, which, *pids):
        (self.dir / which).write_text(''.join(f'{pid}\n' for pid in pids))

    def guard_finished(self, timeout=20):
        try:
            self.guard.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.fail(f'compile-guard had not stopped after {timeout} s; stderr: {self.guard_err.read_text()!r}')
        return self.guard.returncode, self.guard_err.read_text()

    def still_alive(self, pids, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and any(self.alive(p) for p in pids):
            time.sleep(.05)
        return [p for p in pids if self.alive(p)]

    ORPHAN = {'cmd.sh': '/bin/sh "$DIR/inner1.sh" &\necho $! > "$PIDS/inner1"\nwhile [ ! -e "$DIR/end" ]; do sleep 0.2; done\n',
              'inner1.sh': '/bin/sh "$DIR/inner2.sh" &\necho $! > "$PIDS/inner2"\nwhile [ ! -e "$DIR/middle-exit" ]; do sleep 0.1; done\nexit 0\n',
              'inner2.sh': '"$FE" 600 &\necho $! > "$PIDS/frontend"\nwait\n'}

    def orphan_the_frontend(self):
        """command -> inner1 -> inner2 -> swift-frontend; then inner1 exits and launchd adopts inner2 (and so its frontend)."""
        inside = self.pid_files('inner1', 'inner2', 'frontend')
        time.sleep(3)  # the guard samples about once a second: it has seen the whole tree with every parent alive
        (self.dir / 'middle-exit').touch()
        self.still_alive([inside['inner1']])
        self.assertFalse(self.alive(inside['inner1']))
        self.assertEqual(subprocess.run(['/bin/ps', '-p', str(inside['inner2']), '-o', 'ppid='], capture_output=True, text=True).stdout.strip(), '1')
        self.assertTrue(self.alive(inside['inner2']) and self.alive(inside['frontend']))
        return inside

    def test_large_profile_stop_kills_only_its_own_process_tree(self):
        self.start_guard({'cmd.sh': '/bin/sh "$DIR/inner1.sh" &\necho $! > "$PIDS/inner1"\nwait\n',
                          'inner1.sh': '/bin/sh "$DIR/inner2.sh" &\necho $! > "$PIDS/inner2"\nwait\n',
                          'inner2.sh': '"$FE" 600 &\necho $! > "$PIDS/frontend"\nwait\n'})  # command -> sh -> sh -> swift-frontend
        inside = self.pid_files('inner1', 'inner2', 'frontend')
        self.assertTrue(all(self.alive(p) for p in inside.values()) and self.alive(self.decoy.pid))
        self.mark('trip', inside['frontend'])  # the command's own swift-frontend now reports an absurd RSS
        code, err = self.guard_finished()
        self.assertEqual(code, 137, err)
        self.assertIn('compile-guard: STOPPED: a swift-frontend passed', err)
        self.assertEqual(self.still_alive(list(inside.values())), [])
        self.assertIsNone(self.decoy.poll())  # the swift-frontend outside the tree is untouched
        self.assertTrue(self.alive(self.decoy.pid))

    def test_large_profile_stop_reaches_a_process_whose_parent_exited_before_the_trip(self):
        self.start_guard(self.ORPHAN)
        inside = self.orphan_the_frontend()
        self.mark('trip', inside['frontend'])
        code, err = self.guard_finished()
        self.assertEqual(code, 137, err)
        self.assertEqual(self.still_alive([inside['inner2'], inside['frontend']]), [])  # adopted by launchd, still this run's
        self.assertTrue(self.alive(self.decoy.pid))

    def test_large_profile_does_not_stop_its_run_for_a_foreign_oversized_frontend_and_names_it(self):
        self.start_guard({'cmd.sh': '"$FE" 600 &\necho $! > "$PIDS/frontend"\nwhile [ ! -e "$DIR/end" ]; do sleep 0.2; done\n'})
        inside = self.pid_files('frontend')
        self.mark('trip', self.decoy.pid)  # the decoy, which is not in the command's tree, now reports an absurd RSS
        time.sleep(4)  # several samples
        self.assertIsNone(self.guard.poll(), 'the run was stopped for a swift-frontend that is not its own')
        self.assertTrue(self.alive(self.decoy.pid) and self.alive(inside['frontend']))
        (self.dir / 'end').touch()
        code, err = self.guard_finished()
        self.assertEqual(code, 0, err)  # the command finished on its own
        self.assertNotIn('STOPPED', err)
        self.assertEqual(err.count(f'NOTE: swift-frontend pid {self.decoy.pid} holds'), 1, err)  # named, once
        self.assertIn('was NOT stopped', err)
        self.assertTrue(self.alive(self.decoy.pid))

    def test_large_profile_never_signals_a_pid_whose_start_time_changed(self):
        self.start_guard(self.ORPHAN)
        inside = self.orphan_the_frontend()
        # To the guard those two pids now belong to other processes (a different start time): it can no longer prove they are its own.
        self.mark('reuse', inside['inner2'], inside['frontend'])
        self.mark('trip', inside['frontend'])
        time.sleep(4)
        self.assertIsNone(self.guard.poll(), 'the guard stopped its run for a pid it could no longer prove was its own')
        self.assertTrue(self.alive(inside['frontend']) and self.alive(inside['inner2']))
        (self.dir / 'end').touch()
        code, err = self.guard_finished()
        self.assertEqual(code, 0, err)
        self.assertIn(f'NOTE: swift-frontend pid {inside["frontend"]} holds', err)

    def test_large_profile_stop_freezes_the_tree_so_a_forking_process_leaves_no_survivors(self):
        self.start_guard({'cmd.sh': '"$FE" 600 &\necho $! > "$PIDS/frontend"\n/bin/sh "$DIR/spawner.sh" &\nwait\n',
                          'spawner.sh': 'while [ ! -e "$DIR/go" ]; do sleep 0.05; done\nwhile :; do "$MARK" 600 & sleep 0.005; done\n'})
        inside = self.pid_files('frontend')
        time.sleep(1.5)
        (self.dir / 'go').touch()  # the spawner starts forking about 150 children a second ...
        self.mark('trip', inside['frontend'])  # ... and the guard's next sample stops the run
        code, err = self.guard_finished()
        self.assertEqual(code, 137, err)
        time.sleep(.5)
        out = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
        survivors = [l for l in out.splitlines() if f'{self.dir}/marker-sleep' in l]
        self.assertEqual(survivors, [], 'processes forked while the guard was stopping the run survived it')

    TOTAL_SCRIPT = {'cmd.sh': '"$FE" 600 &\necho $! > "$PIDS/frontend"\nwhile [ ! -e "$DIR/end" ]; do sleep 0.2; done\n'}

    def test_large_profile_stops_its_own_run_when_the_machine_total_is_over_the_cap_and_names_the_others(self):
        # Per-frontend cap out of reach, total cap 2000 GB; an inflated row (about 95 TB) is far over the total. The two inflated rows
        # belong to frontends OUTSIDE the command's tree, and this run's own frontend is tiny.
        self.start_guard(self.TOTAL_SCRIPT, COS_COMPILE_MAX_FRONTEND_GB='100000', COS_COMPILE_MAX_TOTAL_GB='2000')
        inside = self.pid_files('frontend')
        other = subprocess.Popen([str(self.fe), '600'])  # a second foreign swift-frontend
        time.sleep(1.5)  # the guard has sampled the machine under the cap: nothing yet
        self.assertIsNone(self.guard.poll())
        self.mark('trip', self.decoy.pid, other.pid)
        code, err = self.guard_finished()
        self.assertEqual(code, 137, err)  # our run stops ...
        self.assertIn('compile-guard: STOPPED: all swift-frontends on this Mac passed 2000 GB together', err)
        self.assertIn("this run's own: 0 GB", err)
        self.assertIn('Not stopped, not touched:', err)
        self.assertIn(f'pid {self.decoy.pid} (', err)  # ... naming the offenders ...
        self.assertIn(f'pid {other.pid} (', err)
        self.assertEqual(self.still_alive([inside['frontend']]), [])
        self.assertIsNone(self.decoy.poll()); self.assertIsNone(other.poll())  # ... and never signalling them
        self.assertTrue(self.alive(self.decoy.pid) and self.alive(other.pid))

    def test_large_profile_own_total_over_the_cap_stops_with_its_own_wording(self):
        self.start_guard(self.TOTAL_SCRIPT, COS_COMPILE_MAX_FRONTEND_GB='100000', COS_COMPILE_MAX_TOTAL_GB='2000')
        inside = self.pid_files('frontend')
        self.mark('trip', inside['frontend'])
        code, err = self.guard_finished()
        self.assertEqual(code, 137, err)
        self.assertIn("compile-guard: STOPPED: all of this run's swift-frontends passed 2000 GB together", err)
        self.assertEqual(self.still_alive([inside['frontend']]), [])
        self.assertTrue(self.alive(self.decoy.pid))

    def test_large_profile_total_under_the_cap_changes_nothing(self):
        self.start_guard(self.TOTAL_SCRIPT, COS_COMPILE_MAX_FRONTEND_GB='100000', COS_COMPILE_MAX_TOTAL_GB='2000')
        inside = self.pid_files('frontend')
        time.sleep(3)  # a few samples, nothing over any cap
        self.assertIsNone(self.guard.poll())
        (self.dir / 'end').touch()
        code, err = self.guard_finished()
        self.assertEqual(code, 0, err)
        self.assertEqual(err, '')
        self.assertTrue(self.alive(inside['frontend']) and self.alive(self.decoy.pid))


if __name__ == '__main__':
    unittest.main()
