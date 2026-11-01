#!/usr/bin/env python3
"""Behavioral receipt invalidation checks, using a stand-in compiler."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name('reuse-compile.py')

FAKE_COMPILER = '''#!/usr/bin/env python3
import os,pathlib,sys,time
if '--version' in sys.argv:
    print('compiler-test-1')
else:
    with open('count', 'a') as tally:
        tally.write('x')
    if os.environ.get('FAKE_SLEEP'):
        time.sleep(float(os.environ['FAKE_SLEEP']))
    out=pathlib.Path(sys.argv[sys.argv.index('-o')+1] if '-o' in sys.argv else 'app')
    out.write_text('binary')
    out.chmod(0o755)
'''


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for directory in ('Sources', 'Tests', 'bin'):
            (self.root / directory).mkdir()
        (self.root / 'Sources/a.swift').write_text('source')
        (self.root / 'Tests/fixture.json').write_text('{}')
        (self.root / 'Package.resolved').write_text('dependency')
        self.script('Tests/compile-guard.sh', '#!/bin/sh\nexec "$@"\n')
        self.script('bin/xcrun', '#!/bin/sh\ncase "$1" in --show-sdk-build-version) printf "${FAKE_SDK_BUILD:-1A1}";; *) printf sdk-test;; esac\n')
        self.script('bin/compiler', FAKE_COMPILER)
        self.env = dict(os.environ, PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'])
        for key in ('COS_TEST_KIT_PERSIST', 'COS_TEST_KIT_STORE', 'COS_TEST_KIT_REUSE_MAX_ENTRIES', 'COS_TEST_KIT_REUSE_MAX_BYTES',
                    'FAKE_SLEEP', 'FAKE_SDK_BUILD', 'SDKROOT', 'COS_TEST_COMPILER_MODE'):
            self.env.pop(key, None)

    def tearDown(self):
        self.temp.cleanup()

    def script(self, name, content):
        path = self.root/name
        path.write_text(content)
        path.chmod(0o700)

    def count(self):
        return str(len((self.root/'count').read_text()))

    def argv(self, flags=(), run=None, script=SCRIPT, named=()):
        """run=None: the output and receipt sit in the checkout. run=n: a per-run scratch directory, as run.sh's $TMP."""
        where = self.root if run is None else self.root/f'run{run}'
        where.mkdir(exist_ok=True)
        out = ['-o', str(where/'app')] if run is not None else []
        return [sys.executable, str(script), '--root', str(self.root), '--receipt', str(where/'receipt.json'),
                '--output', str(where/'app'), '--', str(self.root/'Tests/compile-guard.sh'), 'compiler', *out, *named, *flags]

    def start(self, flags=(), run=None, env=None, script=SCRIPT, named=()):
        return subprocess.Popen(self.argv(flags, run, script, named), cwd=self.root, env=env or self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def run_compile(self, flags=(), run=None, script=SCRIPT, named=()):
        return subprocess.run(self.argv(flags, run, script, named), cwd=self.root, env=self.env, capture_output=True, text=True)


class ReuseTests(Base):
    def test_exact_reuse_and_each_input_invalidation(self):
        self.assertEqual(self.run_compile().returncode, 0)
        self.assertIn('verified', self.run_compile().stdout)
        self.assertEqual(self.count(), '1')
        for index, path in enumerate(('Sources/a.swift', 'Package.resolved'), 2):
            (self.root/path).write_text('changed')
            self.assertEqual(self.run_compile().returncode, 0)
            self.assertEqual(self.count(), str(index))
        # Narrowed: a Tests/ file the command does not name cannot change the app build, so it does not rebuild it.
        (self.root/'Tests/fixture.json').write_text('changed')
        self.assertIn('verified', self.run_compile().stdout)
        self.assertEqual(self.count(), '3')
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '4')
        # The environment is an allowlist: a session variable cannot change the key, a toolchain variable does.
        self.env.update(COS_TEST_COMPILER_MODE='different', SESSION_ID='abc', COS_COMPILE_SLOTS='3')
        self.assertIn('verified', self.run_compile(['-flag']).stdout)
        self.assertEqual(self.count(), '4')
        self.env['SDKROOT'] = '/some/other/sdk'
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '5')
        (self.root/'app').write_text('tampered')
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '6')
        compiler=self.root/'bin/compiler'
        compiler.write_text(compiler.read_text().replace('compiler-test-1','compiler-test-2'))
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '7')

    def test_resources_helper_sources_and_package_manifest_are_inputs(self):
        for directory in ('HelperSources', 'Resources'):
            (self.root/directory).mkdir()
            (self.root/directory/'x').write_text('one')
        (self.root/'Package.swift').write_text('manifest')
        self.run_compile()
        for index, path in enumerate(('HelperSources/x', 'Resources/x', 'Package.swift'), 2):
            (self.root/path).write_text('two')
            self.run_compile()
            self.assertEqual(self.count(), str(index), path)

    def test_the_sdk_build_version_is_an_input(self):
        self.run_compile()
        self.env['FAKE_SDK_BUILD'] = '2B2'
        self.run_compile()
        self.assertEqual(self.count(), '2')

    def test_the_guard_scripts_and_this_script_are_inputs(self):
        copy = self.root/'rc.py'
        shutil.copy(SCRIPT, copy)
        self.run_compile(script=copy)
        self.run_compile(script=copy)
        self.assertEqual(self.count(), '1')
        copy.write_text(copy.read_text() + '# an edit to reuse-compile.py\n')
        self.run_compile(script=copy)
        self.assertEqual(self.count(), '2')
        guard = self.root/'Tests/compile-guard.sh'
        guard.write_text(guard.read_text() + '# an edit to the guard\n')
        self.run_compile(script=copy)
        self.assertEqual(self.count(), '3')
        bounded = self.root/'Tests/compile-bounded.py'
        bounded.write_text('# bounded 1\n')
        self.run_compile(script=copy)
        self.assertEqual(self.count(), '4')
        bounded.write_text('# bounded 2\n')
        self.run_compile(script=copy)
        self.assertEqual(self.count(), '5')
        self.run_compile(script=copy)
        self.assertEqual(self.count(), '5')

    def test_a_file_the_command_names_is_an_input_but_its_own_output_is_not(self):
        gen = self.root/'Tests/gen.swift'
        gen.write_text('one')
        self.run_compile(named=[str(gen)])
        self.assertIn('verified', self.run_compile(named=[str(gen)]).stdout)  # the output now exists; still the same key
        self.assertEqual(self.count(), '1')
        gen.write_text('two')
        self.run_compile(named=[str(gen)])
        self.assertEqual(self.count(), '2')
        self.run_compile(named=[str(self.root/'app')])  # naming the output as an argument never makes it an input
        self.run_compile(named=[str(self.root/'app')])
        self.assertEqual(self.count(), '3')

    def test_the_per_run_scratch_directory_is_not_part_of_the_key(self):
        self.run_compile(run=1)
        self.assertEqual(self.run_compile(run=1).stdout.count('verified'), 1)
        self.run_compile(run=2)  # a new $TMP with no receipt and no output: the same command, nothing to reuse locally
        self.assertEqual(self.count(), '2')
        outside = [Path(tempfile.mkdtemp(prefix='cos-control-tests.', dir='/tmp')) for _ in range(2)]
        try:
            for d in outside:
                (d/'gen.swift').write_text('generated')
            self.run_compile(run=3, named=[str(outside[0]/'gen.swift')])
            self.assertIn('verified', self.run_compile(run=3, named=[str(outside[1]/'gen.swift')]).stdout)
            self.assertEqual(self.count(), '3')
        finally:
            for d in outside:
                shutil.rmtree(d, ignore_errors=True)

    def test_failed_compile_cannot_reuse_previous_receipt(self):
        self.assertEqual(self.run_compile().returncode, 0)
        self.script('bin/compiler', '#!/bin/sh\nif [ "$1" = "--version" ]; then echo test; else exit 42; fi\n')
        self.assertEqual(self.run_compile().returncode, 42)
        self.assertFalse((self.root/'receipt.json').exists())

    def test_source_change_during_compile_rejects_success(self):
        compiler=self.root/'bin/compiler'
        compiler.write_text(compiler.read_text()+"\n    pathlib.Path('Sources/a.swift').write_text('raced')\n")
        self.assertEqual(self.run_compile().returncode, 1)
        self.assertFalse((self.root/'receipt.json').exists())

    def test_guard_cannot_be_omitted(self):
        command = self.argv()
        command[command.index('--') + 1] = str(self.root/'bin/compiler')
        self.assertEqual(subprocess.run(command, cwd=self.root, env=self.env, capture_output=True, text=True).returncode, 2)


class PersistentReuseTests(Base):
    """COS_TEST_KIT_PERSIST=1 + COS_TEST_KIT_STORE: the finished binary outlives the run's scratch directory."""

    def setUp(self):
        super().setUp()
        self.store = self.root/'store'
        self.env.update(COS_TEST_KIT_PERSIST='1', COS_TEST_KIT_STORE=str(self.store))

    def bins(self):
        return sorted((self.store/'reuse').glob('*.bin')) if (self.store/'reuse').exists() else []

    def test_the_next_run_restores_the_binary_instead_of_compiling(self):
        self.assertEqual(self.run_compile(run=1).returncode, 0)
        self.assertEqual(len(self.bins()), 1)
        r = self.run_compile(run=2)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('restored from the persistent store', r.stdout)
        self.assertEqual(self.count(), '1')
        out = self.root/'run2/app'
        self.assertEqual(out.read_text(), 'binary')
        self.assertTrue(out.stat().st_mode & stat.S_IXUSR, 'the restored binary lost its executable bit')
        self.assertIn('verified', self.run_compile(run=2).stdout)  # the same run's second call uses the run's own receipt
        self.assertEqual(self.count(), '1')
        self.assertEqual(oct((self.store/'reuse').stat().st_mode & 0o777), '0o700')

    def test_off_switch_means_nothing_is_kept_between_runs(self):
        for n, persist in enumerate((None, '0', '', 'true', 'yes')):
            with self.subTest(persist=persist):
                shutil.rmtree(self.root/'store', ignore_errors=True)
                (self.root/'count').unlink(missing_ok=True)
                self.env.pop('COS_TEST_KIT_PERSIST', None)
                if persist is not None:
                    self.env['COS_TEST_KIT_PERSIST'] = persist
                self.run_compile(run=n*10 + 1)
                self.run_compile(run=n*10 + 2)
                self.assertEqual(self.count(), '2')
                self.assertFalse(self.store.exists())
        self.env['COS_TEST_KIT_PERSIST'] = '1'
        self.env.pop('COS_TEST_KIT_STORE')  # the flag with no store
        (self.root/'count').unlink()
        self.run_compile(run=91)
        self.run_compile(run=92)
        self.assertEqual(self.count(), '2')

    def test_a_changed_input_misses_and_the_new_build_is_what_the_next_run_gets(self):
        self.run_compile(run=1)
        (self.root/'Sources/a.swift').write_text('changed')
        self.run_compile(run=2)
        self.assertEqual(self.count(), '2')
        self.assertEqual(len(self.bins()), 2)
        self.assertIn('restored', self.run_compile(run=3).stdout)
        self.assertEqual(self.count(), '2')
        (self.root/'Tests/fixture.json').write_text('a harness edit')  # narrowed away: still a hit
        self.assertIn('restored', self.run_compile(run=4).stdout)
        self.assertEqual(self.count(), '2')

    def test_a_second_checkout_never_restores_the_first_ones_binary(self):
        other = Path(tempfile.mkdtemp(prefix='checkout2.'))
        shutil.rmtree(other)
        try:
            shutil.copytree(self.root, other, ignore=shutil.ignore_patterns('store', 'count', 'app', 'receipt.json', 'run*'))

            def build(where):  # the output sits in the checkout itself, so only the command's own paths tell checkouts apart
                command = [sys.executable, str(SCRIPT), '--root', str(where), '--receipt', str(where/'receipt.json'),
                           '--output', str(where/'app'), '--', str(where/'Tests/compile-guard.sh'), 'compiler', '-o', str(where/'app')]
                return subprocess.run(command, cwd=self.root, env=self.env, capture_output=True, text=True)
            self.assertEqual(build(self.root).returncode, 0)
            r = build(other)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn('restored', r.stdout)
            self.assertEqual(self.count(), '2')
        finally:
            shutil.rmtree(other, ignore_errors=True)

    def test_a_tampered_stored_binary_is_never_restored(self):
        self.run_compile(run=1)
        self.bins()[0].write_text('evil')
        self.run_compile(run=2)
        self.assertEqual(self.count(), '2')
        self.assertEqual((self.root/'run2/app').read_text(), 'binary')
        self.assertEqual(self.bins()[0].read_text(), 'binary')  # and the rebuild replaced the bad copy

    def test_the_store_keeps_the_newest_binaries_within_the_cap(self):
        self.env['COS_TEST_KIT_REUSE_MAX_ENTRIES'] = '2'
        for i in range(4):
            (self.root/'Sources/a.swift').write_text(f'v{i}')
            self.run_compile(run=i)
            time.sleep(0.02)
        self.assertEqual(len(self.bins()), 2)
        self.assertEqual(len(list((self.store/'reuse').glob('*.json'))), 2)
        (self.root/'Sources/a.swift').write_text('v3')
        self.assertIn('restored', self.run_compile(run=10).stdout)
        (self.root/'Sources/a.swift').write_text('v0')
        self.assertNotIn('restored', self.run_compile(run=11).stdout)

    def test_the_byte_cap_always_keeps_the_newest(self):
        self.env['COS_TEST_KIT_REUSE_MAX_BYTES'] = '1'
        for i in range(3):
            (self.root/'Sources/a.swift').write_text(f'v{i}')
            self.run_compile(run=i)
        self.assertEqual(len(self.bins()), 1)

    def test_a_half_written_pair_is_swept(self):
        self.run_compile(run=1)
        (self.store/'reuse'/('a'*64 + '.bin')).write_text('interrupted')
        (self.root/'Sources/a.swift').write_text('two')
        self.run_compile(run=2)
        self.assertEqual([p.name for p in (self.store/'reuse').iterdir() if p.name.startswith('a')], [])

    def test_an_icloud_or_relative_store_is_refused(self):
        home = self.root/'home'
        self.env['HOME'] = str(home)
        places = (home/'Documents/s', home/'Desktop/s', home/'Library/Mobile Documents/com~apple~CloudDocs/s', 'relative-store')
        for n, place in enumerate(places):
            with self.subTest(place=str(place)):
                self.env['COS_TEST_KIT_STORE'] = str(place)
                (self.root/'count').unlink(missing_ok=True)
                self.run_compile(run=n*10 + 1)
                self.run_compile(run=n*10 + 2)
                self.assertEqual(self.count(), '2')
                self.assertFalse(Path(str(place)).is_absolute() and Path(place).exists())
        self.assertFalse((self.root/'relative-store').exists())

    def test_processes_racing_on_one_fingerprint_all_succeed_and_leave_one_clean_entry(self):
        env = dict(self.env, FAKE_SLEEP='0.4')
        procs = [self.start(run=i, env=env) for i in range(5)]
        for p in procs:
            out, err = p.communicate(timeout=60)
            self.assertEqual(p.returncode, 0, err)
        for i in range(5):
            self.assertEqual((self.root/f'run{i}/app').read_text(), 'binary')
        self.assertEqual(len(self.bins()), 1)
        entry = json.loads(self.bins()[0].with_suffix('.json').read_text())
        import hashlib
        self.assertEqual(hashlib.sha256(self.bins()[0].read_bytes()).hexdigest(), entry['output'])
        self.assertEqual([p.name for p in (self.store/'reuse').iterdir() if p.name.startswith('.save-')], [])

    def test_processes_racing_with_a_tight_cap_leave_only_whole_entries(self):
        env = dict(self.env, FAKE_SLEEP='0.15', COS_TEST_KIT_REUSE_MAX_ENTRIES='2')
        for rounds in range(3):
            procs = [self.start(flags=[f'-DV{i % 5}'], run=rounds*10 + i, env=env) for i in range(10)]
            for p in procs:
                out, err = p.communicate(timeout=120)
                self.assertEqual(p.returncode, 0, err)
            names = sorted(p.name for p in (self.store/'reuse').iterdir() if p.name != '.lock')
            self.assertLessEqual(len(self.bins()), 2)
            self.assertEqual([n.rsplit('.', 1)[0] for n in names if n.endswith('.bin')],
                             [n.rsplit('.', 1)[0] for n in names if n.endswith('.json')])
            self.assertEqual(len(names), 2 * len(self.bins()), names)


if __name__ == '__main__':
    unittest.main()
