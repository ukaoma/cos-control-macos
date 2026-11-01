#!/usr/bin/env python3
"""Behavioral receipt invalidation checks, using a stand-in compiler."""
import hashlib
import importlib.util
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


def load_module():
    spec = importlib.util.spec_from_file_location('reuse_compile_under_test', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The fingerprint EXACTLY as it was at 9fc9550, before the persistent store existed (git show 9fc9550:Tests/reuse-compile.py).
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def golden_fingerprint(root, command, toolchain):
    files = []
    for name in ('Sources', 'HelperSources', 'Tests', 'scripts', 'Resources',
                 'Package.swift', 'Package.resolved'):
        path = root / name
        candidates = sorted(path.rglob('*')) if path.is_dir() else [path]
        for item in candidates:
            if item.is_file() and '__pycache__' not in item.parts:
                files.append((str(item.relative_to(root)), digest(item)))
    env = sorted((key, value) for key, value in os.environ.items() if key not in ('_', 'SHLVL'))
    material = dict(files=files, command=command, toolchain=toolchain, env=env, cwd=os.getcwd())
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


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
        self.script('bin/sw_vers', '#!/bin/sh\nprintf "${FAKE_HOST_BUILD:-24A1}"\n')
        self.script('bin/compiler', FAKE_COMPILER)
        self.env = dict(os.environ, PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'])
        for key in ('COS_TEST_KIT_PERSIST', 'COS_TEST_KIT_STORE', 'COS_TEST_KIT_REUSE_MAX_ENTRIES', 'COS_TEST_KIT_REUSE_MAX_BYTES',
                    'FAKE_SLEEP', 'FAKE_SDK_BUILD', 'FAKE_HOST_BUILD', 'SDKROOT', 'COS_TEST_COMPILER_MODE',
                    'COS_TEST_KIT_MIN_FREE_BYTES', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET',
                    'SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH'):
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
    """Persistence OFF (no COS_TEST_KIT_PERSIST): exactly the behavior this script always had."""

    def test_exact_reuse_and_each_input_invalidation(self):
        self.assertEqual(self.run_compile().returncode, 0)
        self.assertIn('verified', self.run_compile().stdout)
        self.assertEqual(self.count(), '1')
        for index, path in enumerate(('Sources/a.swift', 'Tests/fixture.json', 'Package.resolved'), 2):
            (self.root/path).write_text('changed')
            self.assertEqual(self.run_compile().returncode, 0)
            self.assertEqual(self.count(), str(index))
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '5')
        self.env['COS_TEST_COMPILER_MODE'] = 'different'
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '6')
        (self.root/'app').write_text('tampered')
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '7')
        compiler=self.root/'bin/compiler'
        compiler.write_text(compiler.read_text().replace('compiler-test-1','compiler-test-2'))
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '8')

    def test_scripts_and_any_environment_variable_still_invalidate(self):
        (self.root/'scripts').mkdir()
        (self.root/'scripts/x.sh').write_text('one')
        self.run_compile()
        (self.root/'scripts/x.sh').write_text('two')
        self.run_compile()
        self.assertEqual(self.count(), '2')
        self.env['SESSION_ID'] = 'abc'
        self.run_compile()
        self.assertEqual(self.count(), '3')

    def test_the_fingerprint_is_byte_identical_to_the_original(self):
        module = load_module()
        for directory in ('HelperSources', 'Resources', 'scripts'):
            (self.root/directory).mkdir()
            (self.root/directory/'f').write_text(directory)
        (self.root/'Package.swift').write_text('manifest')
        command = [str(self.root/'Tests/compile-guard.sh'), 'compiler', '-flag', str(self.root/'Sources/a.swift')]
        toolchain = ['/x/compiler', 'abc', 'v1', '/sdk', '15.1']
        saved = dict(os.environ)
        try:
            os.environ.update(SOME_VAR='1', _='ignored')
            cwd = os.getcwd()
            os.chdir(self.root)
            try:
                self.assertEqual(module.legacy_fingerprint(self.root, command, toolchain),
                                 golden_fingerprint(self.root, command, toolchain))
                (self.root/'Tests/fixture.json').write_text('changed')
                self.assertEqual(module.legacy_fingerprint(self.root, command, toolchain),
                                 golden_fingerprint(self.root, command, toolchain))
            finally:
                os.chdir(cwd)
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_nothing_is_persisted_and_the_new_variables_change_nothing_when_off(self):
        self.env.update(COS_TEST_KIT_STORE=str(self.root/'store'), COS_TEST_KIT_REUSE_MAX_ENTRIES='1')
        self.run_compile(run=1)
        self.run_compile(run=2)
        self.assertEqual(self.count(), '2')
        self.assertFalse((self.root/'store').exists())

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

    ALLOWED_ENV = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET', 'SWIFT_DETERMINISTIC_HASHING',
                   'SOURCE_DATE_EPOCH')

    def setUp(self):
        super().setUp()
        self.store = self.root/'store'
        self.env.update(COS_TEST_KIT_PERSIST='1', COS_TEST_KIT_STORE=str(self.store))

    def bins(self):
        return sorted((self.store/'reuse').glob('*.bin')) if (self.store/'reuse').exists() else []

    # ---- the narrowed fingerprint (only while persisting)
    def test_exact_reuse_and_each_input_invalidation_narrowed(self):
        self.assertEqual(self.run_compile().returncode, 0)
        self.assertIn('verified', self.run_compile().stdout)
        self.assertEqual(self.count(), '1')
        for index, path in enumerate(('Sources/a.swift', 'Package.resolved'), 2):
            (self.root/path).write_text('changed')
            self.assertEqual(self.run_compile().returncode, 0)
            self.assertEqual(self.count(), str(index))
        # A Tests/ or scripts/ file the command does not name cannot change the app build, so it does not rebuild it.
        (self.root/'Tests/fixture.json').write_text('changed')
        (self.root/'scripts').mkdir()
        (self.root/'scripts/x.sh').write_text('changed')
        self.assertIn('verified', self.run_compile().stdout)
        self.assertEqual(self.count(), '3')
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '4')
        # The environment is an allowlist: a session variable cannot change the key.
        self.env.update(COS_TEST_COMPILER_MODE='different', SESSION_ID='abc', COS_COMPILE_SLOTS='3')
        self.assertIn('verified', self.run_compile(['-flag']).stdout)
        self.assertEqual(self.count(), '4')
        (self.root/'app').write_text('tampered')  # the store still holds the verified binary for this very key
        r = self.run_compile(['-flag'])
        self.assertIn('restored', r.stdout)
        self.assertEqual((self.root/'app').read_text(), 'binary')
        self.assertEqual(self.count(), '4')
        compiler=self.root/'bin/compiler'
        compiler.write_text(compiler.read_text().replace('compiler-test-1','compiler-test-2'))
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual(self.count(), '5')

    def test_every_allowlisted_environment_variable_is_an_input(self):
        self.run_compile()
        for index, key in enumerate(self.ALLOWED_ENV, 2):
            self.env[key] = f'value-{index}'
            self.run_compile()
            self.assertEqual(self.count(), str(index), key)

    def test_the_sdk_build_and_the_host_macos_build_are_inputs(self):
        self.run_compile()
        self.env['FAKE_SDK_BUILD'] = '2B2'
        self.run_compile()
        self.assertEqual(self.count(), '2')
        self.env['FAKE_HOST_BUILD'] = '25Z9'
        self.run_compile()
        self.assertEqual(self.count(), '3')

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
        (self.root/'app').unlink()
        self.assertEqual(self.run_compile(named=[str(self.root/'app')]).returncode, 0)  # the output, named, is never its own input
        self.assertIn('verified', self.run_compile(named=[str(self.root/'app')]).stdout)
        self.assertEqual(self.count(), '3')

    def test_the_per_run_scratch_directory_is_not_part_of_the_key(self):
        outside = [Path(tempfile.mkdtemp(prefix='cos-control-tests.', dir='/tmp')) for _ in range(2)]
        try:
            for d in outside:
                (d/'gen.swift').write_text('generated')
            self.run_compile(run=3, named=[str(outside[0]/'gen.swift')])
            self.assertIn('verified', self.run_compile(run=3, named=[str(outside[1]/'gen.swift')]).stdout)
            self.assertEqual(self.count(), '1')
        finally:
            for d in outside:
                shutil.rmtree(d, ignore_errors=True)

    # ---- the store
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
        again = self.run_compile(run=2).stdout  # the same run's second call uses the run's own receipt, not the store
        self.assertIn('verified exact inputs and output', again)
        self.assertNotIn('restored', again)
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

            def build(where):  # run.sh's shape: cwd is the checkout, which also holds the output
                command = [sys.executable, str(SCRIPT), '--root', str(where), '--receipt', str(where/'receipt.json'),
                           '--output', str(where/'app'), '--', str(where/'Tests/compile-guard.sh'), 'compiler', '-o', str(where/'app')]
                return subprocess.run(command, cwd=where, env=self.env, capture_output=True, text=True)
            self.assertEqual(build(self.root).returncode, 0)
            r = build(other)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn('restored', r.stdout)
            self.assertEqual((self.root/'count').read_text(), 'x')
            self.assertEqual((other/'count').read_text(), 'x', 'the second checkout restored the first one\'s binary')
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
        planted = self.store/'reuse'/('a'*64 + '.bin')  # a binary with no receipt: an interrupted save
        planted.write_text('interrupted')
        self.assertTrue(planted.exists())
        (self.root/'Sources/a.swift').write_text('two')
        self.run_compile(run=2)
        # Exact names: a real fingerprint is random hex and starts with 'a' one time in sixteen.
        self.assertFalse(planted.exists())
        self.assertFalse(planted.with_suffix('.json').exists())
        self.assertEqual(len(self.bins()), 2)  # run 1's and run 2's whole entries are untouched
        self.assertEqual(len(list((self.store/'reuse').glob('*.json'))), 2)

    # ---- where it may persist
    def test_an_icloud_or_relative_store_is_refused_in_any_letter_case(self):
        home = self.root/'home'
        for sub in ('Documents', 'Desktop', 'Library/CloudStorage', 'Library/Mobile Documents'):
            (home/sub).mkdir(parents=True)
        self.env['HOME'] = str(home)
        places = (home/'Documents/s', home/'documents/s', home/'DESKTOP/s', home/'Desktop/a/b/s', home/'Library/CloudStorage/OneDrive-x/s',
                  home/'Library/Mobile Documents/com~apple~CloudDocs/s', home/'library/MOBILE DOCUMENTS/s', 'relative-store')
        for n, place in enumerate(places):
            with self.subTest(place=str(place)):
                self.env['COS_TEST_KIT_STORE'] = str(place)
                (self.root/'count').unlink(missing_ok=True)
                self.run_compile(run=n*10 + 1)
                self.run_compile(run=n*10 + 2)
                self.assertEqual(self.count(), '2')
                self.assertEqual([p.name for p in home.glob('**/*') if p.name in ('reuse', '.origin')], [])
        self.assertFalse((self.root/'relative-store').exists())
        good = home/'Library/Caches/COS/kits/abc123'
        self.env['COS_TEST_KIT_STORE'] = str(good)
        self.run_compile(run=500)
        self.assertEqual(len(list((good/'reuse').glob('*.bin'))), 1)

    def test_environment_that_changes_the_compile_but_is_not_hashed_turns_persistence_off(self):
        cases = {'SWIFT_DRIVER_SWIFT_FRONTEND_EXEC': '/x/frontend', 'SWIFT_DRIVER_SWIFT_AUTOLINK_EXTRACT_EXEC': '/x/y',
                 'DYLD_LIBRARY_PATH': '/x', 'DYLD_FALLBACK_LIBRARY_PATH': '/x', 'CPATH': '/elsewhere',
                 'C_INCLUDE_PATH': '/usr/local/include', 'LIBRARY_PATH': '/elsewhere'}
        for n, (key, value) in enumerate(cases.items()):
            with self.subTest(key=key):
                shutil.rmtree(self.store, ignore_errors=True)
                (self.root/'count').unlink(missing_ok=True)
                self.env[key] = value
                try:
                    r1 = self.run_compile(run=n*10 + 1)
                    self.run_compile(run=n*10 + 2)
                finally:
                    del self.env[key]
                self.assertEqual(self.count(), '2', r1.stderr)
                self.assertIn(key, r1.stderr)
                self.assertFalse(self.store.exists())
        # The one value /usr/bin/python3 itself puts in CPATH and LIBRARY_PATH is not a reason to refuse.
        self.env.update(CPATH='/usr/local/include', LIBRARY_PATH='/usr/local/lib')
        (self.root/'count').unlink()
        self.run_compile(run=900)
        self.assertEqual(len(self.bins()), 1)

    def test_a_command_with_unhashed_search_paths_does_not_persist(self):
        directory = self.root/'somedir'
        directory.mkdir()
        cases = {'-I': ['-I', str(directory)], '-F': ['-F', str(directory)], '-L': ['-L', str(directory)],
                 '-I joined': [f'-I{directory}'], '-sdk': ['-sdk', str(directory)], '-Xcc': ['-Xcc', '-Dx'],
                 '-Xlinker directory': ['-Xlinker', str(directory)]}
        for n, (label, named) in enumerate(cases.items()):
            with self.subTest(label=label):
                shutil.rmtree(self.store, ignore_errors=True)
                (self.root/'count').unlink(missing_ok=True)
                self.run_compile(run=n*10 + 1, flags=named)
                self.run_compile(run=n*10 + 2, flags=named)
                self.assertEqual(self.count(), '2')
                self.assertFalse(self.store.exists())
        (self.root/'Info.plist').write_text('plist')  # a FILE after -Xlinker is the real sectcreate lanes: allowed
        shutil.rmtree(self.store, ignore_errors=True)
        self.run_compile(run=900, flags=['-Xlinker', str(self.root/'Info.plist')])
        self.assertEqual(len(self.bins()), 1)

    # ---- housekeeping and failure behavior
    def test_the_store_carries_its_origin_and_is_touched_on_every_use(self):
        self.run_compile(run=1)
        origin = self.store/'.origin'
        self.assertEqual(json.loads(origin.read_text())['worktree'], str(self.root.resolve()))
        os.utime(origin, (1000, 1000))
        self.run_compile(run=2)
        self.assertGreater(origin.stat().st_mtime, 10**9 + 1000)

    def test_a_cache_write_that_fails_never_fails_a_compile_that_succeeded(self):
        self.run_compile(run=1)
        (self.store/'reuse').chmod(0o500)  # nothing can be saved or trimmed now
        try:
            (self.root/'Sources/a.swift').write_text('another build')
            r = self.run_compile(run=2)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('could not keep', r.stderr)
            self.assertEqual((self.root/'run2/app').read_text(), 'binary')
            self.assertEqual(self.count(), '2')
        finally:
            (self.store/'reuse').chmod(0o700)
        self.assertEqual(len(self.bins()), 1)

    def test_a_store_that_cannot_be_made_or_is_short_of_disk_is_skipped(self):
        locked = self.root/'locked'
        locked.mkdir()
        locked.chmod(0o500)
        try:
            self.env['COS_TEST_KIT_STORE'] = str(locked/'store')
            r = self.run_compile(run=1)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('unusable', r.stderr)
        finally:
            locked.chmod(0o700)
        self.env.update(COS_TEST_KIT_STORE=str(self.store), COS_TEST_KIT_MIN_FREE_BYTES=str(1 << 60))
        (self.root/'count').unlink(missing_ok=True)
        r = self.run_compile(run=2)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('not enough free disk', r.stderr)
        self.assertEqual(self.bins(), [])

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
