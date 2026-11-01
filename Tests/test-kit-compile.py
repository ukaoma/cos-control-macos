#!/usr/bin/env python3
"""Tests/kit-compile.py against a stand-in compiler and guard: never runs Swift."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name('kit-compile.py')

FAKE_SWIFTC = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
if args == ['--version']:
    print(os.environ.get('FAKE_SWIFT_VERSION', 'fake-swift-1')); sys.exit(0)
log = pathlib.Path(os.environ['FAKE_LOG'])
with log.open('a') as s:
    s.write(json.dumps({'args': args, 'cwd': os.getcwd(), 'at': time.time()}) + '\n')
sleep = os.environ.get('FAKE_SLEEP' if '-emit-module' in args else 'FAKE_SLEEP_HARNESS')
if sleep:
    time.sleep(float(sleep))
if os.environ.get('FAKE_FAIL') and any(a.endswith(os.environ['FAKE_FAIL']) for a in args):
    print('error: fake failure', file=sys.stderr); sys.exit(1)
touch = os.environ.get('FAKE_TOUCH')
if touch and ('-emit-module' in args or os.environ.get('FAKE_TOUCH_ANY')):
    pathlib.Path(touch).write_text('changed while compiling')
if '-emit-module' in args:
    pathlib.Path(args[args.index('-emit-module-path') + 1]).write_text('module')
    for a in args:
        if a.endswith('.swift'):
            pathlib.Path(pathlib.Path(a).stem + '.o').write_text('object of ' + pathlib.Path(a).read_text())
    sys.exit(0)
pathlib.Path(args[args.index('-o') + 1]).write_text(json.dumps(args))
'''


class KitBase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for d in ('Sources', 'Tests', 'bin', 'out', 'kits'):
            (self.root / d).mkdir()
        for name in ('Models.swift', 'Views.swift', 'ControlSetup.swift', 'ControlInstance.swift', 'COSControlApp.swift',
                     'LiveTranscript.swift', 'MeetingAskCore.swift', 'MacDictationCore.swift'):
            (self.root / 'Sources' / name).write_text('// ' + name)
        (self.root / 'Tests/A.swift').write_text('// harness a')
        (self.root / 'Tests/B.swift').write_text('// harness b')
        self.exe('Tests/compile-guard.sh', '#!/bin/sh\nexec "$@"\n')
        self.exe('bin/swiftc', FAKE_SWIFTC)
        self.exe('bin/xcrun', '#!/bin/sh\ncase "$1" in --show-sdk-build-version) echo "${FAKE_SDK_BUILD:-1A1}";; *) echo sdk;; esac\n')
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                        FAKE_LOG=str(self.log), COS_TEST_KIT_DIR=str(self.root / 'kits'))
        for key in ('COS_TEST_KIT', 'COS_TEST_KIT_LOG', 'FAKE_FAIL', 'FAKE_TOUCH', 'FAKE_TOUCH_ANY', 'COS_TEST_KIT_PERSIST',
                    'COS_TEST_KIT_STORE', 'COS_TEST_KIT_EVICT_MIN_AGE', 'COS_TEST_KIT_OUT_MAX_ENTRIES',
                    'COS_TEST_KIT_OUT_MAX_BYTES', 'FAKE_SLEEP', 'FAKE_SLEEP_HARNESS', 'FAKE_SDK_BUILD'):
            self.env.pop(key, None)

    def tearDown(self):
        self.temp.cleanup()

    def exe(self, rel, text):
        (self.root / rel).write_text(text)
        (self.root / rel).chmod(0o755)

    def app(self, core=False):
        skip = {'COSControlApp.swift'} | ({'ControlSetup.swift', 'ControlInstance.swift'} if core else set())
        return [str(p) for p in sorted((self.root / 'Sources').glob('*.swift')) if p.name not in skip]

    def command(self, sources, harness=('Tests/A.swift',), flags=('-parse-as-library',), out='lane', extra=(), script=SCRIPT):
        return [sys.executable, str(script), str(self.root / 'Tests/compile-guard.sh'), 'swiftc',
                '-target', 'arm64-apple-macosx14.0', '-swift-version', '6', '-strict-concurrency=complete', *flags,
                *sources, *[str(self.root / h) for h in harness], '-framework', 'AppKit', *extra,
                '-o', str(self.root / 'out' / out)]

    def compile(self, sources, **kw):
        return subprocess.run(self.command(sources, **kw), env=self.env, cwd=self.root, capture_output=True, text=True)

    def start(self, sources, env=None, **kw):
        return subprocess.Popen(self.command(sources, **kw), env=env or self.env, cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line)['args'] for line in self.log.read_text().splitlines()]

    def kit_builds(self):
        return [c for c in self.calls() if '-emit-module' in c]


class KitTests(KitBase):
    def test_one_kit_build_serves_every_lane_and_harness_compiles_alone(self):
        r1 = self.compile(self.app(), out='one')
        r2 = self.compile(self.app(), harness=('Tests/B.swift',), out='two')
        self.assertEqual((r1.returncode, r2.returncode), (0, 0), r1.stderr + r2.stderr)
        self.assertEqual(len(self.kit_builds()), 1)
        kit = self.kit_builds()[0]
        self.assertIn('-enable-testing', kit)
        self.assertEqual(kit[kit.index('-module-name') + 1], 'COSControlKit')
        self.assertEqual(sorted(Path(a).name for a in kit if a.endswith('.swift')),
                         sorted(Path(a).name for a in self.app()))
        harness = json.loads((self.root / 'out/two').read_text())
        swift = [a for a in harness if a.endswith('.swift')]
        self.assertEqual(swift, [str(self.root / 'Tests/B.swift')])
        self.assertEqual(harness[harness.index('-testable-import-module') - 1], '-Xfrontend')
        objects = [harness[i + 1] for i, a in enumerate(harness) if a == '-Xlinker']
        self.assertEqual(sorted(Path(o).name for o in objects), sorted(Path(a).stem + '.o' for a in self.app()))
        self.assertIn('-framework', harness)
        for flag in ('-target', '-swift-version', '-strict-concurrency=complete', '-parse-as-library'):
            self.assertIn(flag, harness)

    def test_old_layout_runs_the_command_as_written(self):
        self.env['COS_TEST_KIT'] = '0'
        self.assertEqual(self.compile(self.app()).returncode, 0)
        (call,) = self.calls()
        self.assertEqual(call[-2:], ['-o', str(self.root / 'out/lane')])
        self.assertEqual([a for a in call if a.endswith('.swift')], self.app() + [str(self.root / 'Tests/A.swift')])
        self.assertNotIn('-testable-import-module', call)

    def test_distinct_sets_and_flags_get_distinct_kits(self):
        self.compile(self.app())
        self.compile(self.app(core=True))
        self.compile([str(self.root / 'Sources/Models.swift')])
        self.compile(self.app(), flags=('-parse-as-library', '-D', 'X'))
        self.assertEqual(len(self.kit_builds()), 4)
        self.compile(self.app(core=True), harness=('Tests/B.swift',))
        self.assertEqual(len(self.kit_builds()), 4)

    def test_source_change_rebuilds_and_restore_reuses(self):
        self.compile(self.app())
        models = self.root / 'Sources/Models.swift'
        original = models.read_text()
        models.write_text('// mutant')
        self.compile(self.app())
        self.assertEqual(len(self.kit_builds()), 2)
        objects = json.loads((self.root / 'out/lane').read_text())
        model_obj = next(o for o in objects if o.endswith('Models.o'))
        self.assertEqual(Path(model_obj).read_text(), 'object of // mutant')
        models.write_text(original)
        self.compile(self.app())
        self.assertEqual(len(self.kit_builds()), 2)
        objects = json.loads((self.root / 'out/lane').read_text())
        self.assertEqual(Path(next(o for o in objects if o.endswith('Models.o'))).read_text(), 'object of ' + original)

    def test_one_byte_in_any_kit_source_rebuilds_the_kit(self):
        self.compile(self.app())
        for name in ('Views.swift', 'ControlInstance.swift'):
            path = self.root / 'Sources' / name
            data = bytearray(path.read_bytes())
            data[-1] ^= 1  # one byte, same length, same mtime second
            path.write_bytes(bytes(data))
        before = len(self.kit_builds())
        self.compile(self.app())
        self.assertEqual(len(self.kit_builds()), before + 1)
        harness = json.loads((self.root / 'out/lane').read_text())
        views = next(o for o in harness if o.endswith('Views.o'))
        self.assertEqual(Path(views).read_text(), 'object of ' + (self.root / 'Sources/Views.swift').read_text())

    def test_harness_change_reuses_the_kit(self):
        self.compile(self.app())
        (self.root / 'Tests/A.swift').write_text('// harness mutant')
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertEqual(len(self.kit_builds()), 1)
        self.assertEqual(len(self.calls()), 3)

    def test_tampered_object_or_flag_or_toolchain_rebuilds(self):
        self.compile(self.app())
        obj = next((self.root / 'kits').glob('app-*/obj/Models.o'))
        obj.write_text('tampered')
        self.compile(self.app())
        self.assertEqual(len(self.kit_builds()), 2)
        self.env['FAKE_SWIFT_VERSION'] = 'fake-swift-2'
        self.compile(self.app())
        self.assertEqual(len(self.kit_builds()), 3)

    def test_kit_failure_is_the_lane_failure(self):
        self.env['FAKE_FAIL'] = 'Views.swift'
        r = self.compile(self.app())
        self.assertEqual(r.returncode, 1)
        self.assertFalse((self.root / 'out/lane').exists())
        self.assertEqual(list((self.root / 'kits').glob('app-*')), [])
        self.assertEqual(len(self.calls()), 1)

    def test_harness_failure_is_the_lane_failure(self):
        self.env['FAKE_FAIL'] = 'A.swift'
        self.assertEqual(self.compile(self.app()).returncode, 1)

    def test_source_changed_during_build_is_refused(self):
        self.env['FAKE_TOUCH'] = str(self.root / 'Sources/Views.swift')
        r = self.compile(self.app())
        self.assertEqual(r.returncode, 1)
        self.assertIn('changed during the build', r.stderr)
        self.assertEqual(list((self.root / 'kits').glob('app-*')), [])

    def test_library_mode_is_explicit_or_implied_never_invented(self):
        models = [str(self.root / 'Sources/Models.swift')]
        self.compile(models, flags=())  # two inputs, no main.swift: already library files
        self.assertEqual(len(self.kit_builds()), 1)
        harness = json.loads((self.root / 'out/lane').read_text())
        self.assertIn('-parse-as-library', harness)
        (self.root / 'Tests/main.swift').write_text('print(1)')
        self.compile(models, harness=('Tests/main.swift',), flags=(), out='script')
        self.assertEqual(len(self.kit_builds()), 1)
        self.assertNotIn('-testable-import-module', self.calls()[-1])
        self.assertNotIn('-parse-as-library', self.calls()[-1])

    def test_unrecognised_shapes_run_as_written(self):
        for flags in (('-parse-as-library', '-typecheck'), ('-parse-as-library', '-module-name', 'X')):
            self.log.unlink(missing_ok=True)
            self.compile(self.app(), flags=flags)
            (call,) = self.calls()
            self.assertEqual(len([a for a in call if a.endswith('.swift')]), len(self.app()) + 1)
        self.log.unlink()
        self.compile(self.app()[:2])  # not a kit set
        (call,) = self.calls()
        self.assertNotIn('-testable-import-module', call)

    def test_identical_plain_build_reuses_binary_until_an_input_changes(self):
        helper = [str(self.root / 'Sources/Views.swift')]
        self.compile(helper, harness=('Tests/A.swift', 'Tests/B.swift'), flags=(), out='h1')
        r = self.compile(helper, harness=('Tests/A.swift', 'Tests/B.swift'), flags=(), out='h2')
        self.assertIn('reused', r.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual((self.root / 'out/h1').read_text(), (self.root / 'out/h2').read_text())
        (self.root / 'Tests/B.swift').write_text('// changed')
        self.compile(helper, harness=('Tests/A.swift', 'Tests/B.swift'), flags=(), out='h3')
        self.assertEqual(len(self.calls()), 2)
        self.compile(helper, harness=('Tests/A.swift', 'Tests/B.swift'), flags=('-D', 'Y'), out='h4')
        self.assertEqual(len(self.calls()), 3)

    def test_plain_build_whose_input_changed_meanwhile_is_not_cached(self):
        helper = [str(self.root / 'Sources/Views.swift')]
        original = (self.root / 'Tests/B.swift').read_text()
        self.env.update(FAKE_TOUCH=str(self.root / 'Tests/B.swift'), FAKE_TOUCH_ANY='1')
        self.compile(helper, harness=('Tests/A.swift', 'Tests/B.swift'), flags=(), out='h1')
        (self.root / 'Tests/B.swift').write_text(original)
        del self.env['FAKE_TOUCH'], self.env['FAKE_TOUCH_ANY']
        self.compile(helper, harness=('Tests/A.swift', 'Tests/B.swift'), flags=(), out='h2')
        self.assertEqual(len(self.calls()), 2)

    def test_no_shared_dir_means_nothing_reused_and_nothing_left(self):
        del self.env['COS_TEST_KIT_DIR']
        self.env['TMPDIR'] = str(self.root)
        before = set(Path('/tmp').glob('cos-test-kit.*'))
        self.compile(self.app())
        self.compile(self.app())
        self.assertEqual(len(self.kit_builds()), 2)
        self.assertEqual(set(Path('/tmp').glob('cos-test-kit.*')), before)
        helper = [str(self.root / 'Sources/Views.swift')]
        self.compile(helper, flags=(), out='p1')
        self.compile(helper, flags=(), out='p2')
        self.assertEqual(len(self.calls()), 6)

    def test_mac_dictation_core_alone_is_one_kit_for_every_lane(self):
        core = [str(self.root / 'Sources/MacDictationCore.swift')]
        for i, harness in enumerate(('Tests/A.swift', 'Tests/B.swift', 'Tests/A.swift')):
            self.assertEqual(self.compile(core, harness=(harness,), out=f'dict{i}').returncode, 0)
        self.assertEqual(len(self.kit_builds()), 1)
        self.assertEqual([Path(a).name for a in self.kit_builds()[0] if a.endswith('.swift')], ['MacDictationCore.swift'])
        lane = json.loads((self.root / 'out/dict1').read_text())
        self.assertEqual([Path(a).name for a in lane if a.endswith('.swift')], ['B.swift'])
        self.assertIn('MacDictationCore.o', [Path(a).name for a in lane])
        path = self.root / 'Sources/MacDictationCore.swift'
        path.write_text(path.read_text() + '!')
        self.compile(core)
        self.assertEqual(len(self.kit_builds()), 2)
        self.assertEqual(len(list((self.root / 'kits').glob('mac-dictation-core-*'))), 2)

    def test_the_per_run_scratch_directory_is_not_part_of_an_output_key(self):
        scratch = [Path(tempfile.mkdtemp(prefix='cos-control-tests.', dir='/tmp')) for _ in range(2)]
        try:
            for d in scratch:
                (d / 'gen.swift').write_text('// generated')
            helper = [str(self.root / 'Sources/Views.swift'), str(scratch[0] / 'gen.swift')]
            self.compile(helper, flags=(), out='g1')
            again = [str(self.root / 'Sources/Views.swift'), str(scratch[1] / 'gen.swift')]
            self.assertIn('reused', self.compile(again, flags=(), out='g2').stderr)
            (scratch[1] / 'gen.swift').write_text('// generated differently')
            self.assertNotIn('reused', self.compile(again, flags=(), out='g3').stderr)
            self.assertEqual(len(self.calls()), 2)
        finally:
            for d in scratch:
                shutil.rmtree(d, ignore_errors=True)

    def test_old_kits_are_evicted(self):
        models = self.root / 'Sources/Models.swift'
        for i in range(7):
            models.write_text(f'// version {i}')
            self.compile(self.app())
        self.assertEqual(len(list((self.root / 'kits').glob('app-*'))), 4)


class PersistentKitTests(KitBase):
    """COS_TEST_KIT_PERSIST=1 + COS_TEST_KIT_STORE: kits and out/ live across runs. Everything else is the per-run layout."""

    def setUp(self):
        super().setUp()
        self.store = self.root / 'store'
        self.env.update(COS_TEST_KIT_PERSIST='1', COS_TEST_KIT_STORE=str(self.store), COS_TEST_KIT_EVICT_MIN_AGE='0')

    def dirs(self, name, where=None):
        return sorted((where or self.store).glob(name + '-' + '[0-9a-f]' * 16))

    def version(self, i):
        (self.root / 'Sources/Models.swift').write_text(f'// version {i}')

    def next_run(self):
        """A new suite run: a fresh per-run kit dir and a fresh output dir, the same persistent store."""
        self.env['COS_TEST_KIT_DIR'] = str(self.root / f'run{len(list(self.root.glob("run*")))}')

    def test_off_switch_is_the_per_run_layout_exactly(self):
        for persist in (None, '0', '', 'true', 'yes'):
            with self.subTest(persist=persist):
                self.env.pop('COS_TEST_KIT_PERSIST', None)
                if persist is not None:
                    self.env['COS_TEST_KIT_PERSIST'] = persist
                self.env['COS_TEST_KIT_DIR'] = str(self.root / f'kits-{persist}')
                self.assertEqual(self.compile(self.app()).returncode, 0)
                self.assertFalse(self.store.exists())
                self.assertEqual(len(self.dirs('app', self.root / f'kits-{persist}')), 1)
        self.env.pop('COS_TEST_KIT_STORE'); self.env['COS_TEST_KIT_PERSIST'] = '1'  # a flag with no store
        self.env['COS_TEST_KIT_DIR'] = str(self.root / 'kits-nostore')
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertEqual(len(self.dirs('app', self.root / 'kits-nostore')), 1)
        self.assertFalse(self.store.exists())

    def test_off_switch_keeps_the_four_kit_eviction_and_no_out_cap(self):
        self.env.pop('COS_TEST_KIT_PERSIST')
        self.env['COS_TEST_KIT_OUT_MAX_ENTRIES'] = '1'
        for i in range(6):
            self.version(i)
            self.compile(self.app())
        self.assertEqual(len(self.dirs('app', self.root / 'kits')), 4)
        helper = [str(self.root / 'Sources/Views.swift')]
        for i in range(4):
            self.compile(helper, flags=('-D', f'X{i}'), out=f'h{i}')
        self.assertEqual(len(list((self.root / 'kits/out').glob('*.sha256'))), 4)

    def test_kits_and_exact_outputs_survive_into_the_next_run(self):
        helper = [str(self.root / 'Sources/Views.swift')]
        self.assertEqual(self.compile(self.app(), out='one').returncode, 0)
        self.compile(helper, flags=(), out='h1')
        self.assertEqual(len(self.dirs('app')), 1)
        self.assertEqual(self.dirs('app', self.root / 'kits'), [])
        before = len(self.calls())
        self.next_run()
        self.assertEqual(self.compile(self.app(), harness=('Tests/B.swift',), out='two').returncode, 0)
        r = self.compile(helper, flags=(), out='h2')
        self.assertIn('reused', r.stderr)
        self.assertEqual(len(self.kit_builds()), 1)
        self.assertEqual(len(self.calls()), before + 1)  # only the second harness compiled
        self.assertEqual((self.root / 'out/h1').read_text(), (self.root / 'out/h2').read_text())

    def test_one_byte_change_rebuilds_the_kit_and_links_the_new_objects(self):
        self.compile(self.app())
        path = self.root / 'Sources/Views.swift'
        data = bytearray(path.read_bytes())
        data[-1] ^= 1
        path.write_bytes(bytes(data))
        self.next_run()
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertEqual(len(self.kit_builds()), 2)
        views = next(o for o in json.loads((self.root / 'out/lane').read_text()) if o.endswith('Views.o'))
        self.assertEqual(Path(views).read_text(), 'object of ' + path.read_text())

    def test_the_key_carries_this_script_the_guard_scripts_and_the_sdk_build(self):
        script = self.root / 'kc.py'
        script.write_text(SCRIPT.read_text())
        builds = lambda: len(self.kit_builds())
        self.compile(self.app(), script=script)
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 1)
        script.write_text(script.read_text() + '# an edit to kit-compile.py\n')
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 2)
        guard = self.root / 'Tests/compile-guard.sh'
        guard.write_text(guard.read_text() + '# an edit to the guard\n')
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 3)
        bounded = self.root / 'Tests/compile-bounded.py'
        bounded.write_text('# bounded 1\n')
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 4)
        bounded.write_text('# bounded 2\n')
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 5)
        self.env['FAKE_SDK_BUILD'] = '2B2'
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 6)
        self.compile(self.app(), script=script)
        self.assertEqual(builds(), 6)

    def test_eviction_keeps_the_newest_two_keys_per_kit_name(self):
        models = [str(self.root / 'Sources/Models.swift')]
        for i in range(4):
            self.version(i)
            self.compile(self.app())
            self.compile(models)
        self.compile([str(self.root / f'Sources/{n}') for n in ('LiveTranscript.swift', 'MeetingAskCore.swift', 'Models.swift')])
        self.assertEqual([len(self.dirs(n)) for n in ('app', 'models', 'meeting-core')], [2, 2, 1])
        for name in ('app', 'models'):
            kept = {(d / 'obj/Models.o').read_text() for d in self.dirs(name)}
            self.assertEqual(kept, {'object of // version 2', 'object of // version 3'}, name)

    def test_a_kit_used_within_the_eviction_age_is_never_evicted(self):
        del self.env['COS_TEST_KIT_EVICT_MIN_AGE']  # the default: two hours, longer than any suite
        for i in range(5):
            self.version(i)
            self.compile(self.app())
        kits = sorted(self.dirs('app'), key=lambda d: d.stat().st_mtime)
        self.assertEqual(len(kits), 5)
        for old in kits[:3]:
            os.utime(old, (time.time() - 36000, time.time() - 36000))
        self.version(5)
        self.compile(self.app())
        survivors = {(d / 'obj/Models.o').read_text() for d in self.dirs('app')}
        self.assertEqual(survivors, {f'object of // version {i}' for i in (3, 4, 5)})

    def test_a_kit_a_lane_is_still_linking_against_is_not_evicted_from_under_it(self):
        self.version(0)
        self.assertEqual(self.compile(self.app()).returncode, 0)  # built by an earlier lane: the slow one only REUSES it
        before = len(self.calls())
        slow = self.start(self.app(), env=dict(self.env, FAKE_SLEEP_HARNESS='4'), out='slow')
        deadline = time.time() + 20
        while time.time() < deadline and len(self.calls()) == before:
            time.sleep(0.05)
        (v0,) = self.dirs('app')
        for i in (1, 2, 3):
            self.version(i)
            self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertTrue(v0.is_dir(), 'the kit a lane is linking against was evicted')
        self.assertIsNone(slow.poll(), 'the slow lane should still be linking')
        out, err = slow.communicate(timeout=30)
        self.assertEqual(slow.returncode, 0, err)
        self.version(4)
        self.compile(self.app())
        self.assertFalse(v0.exists(), 'once nobody uses it, the oldest kit must be evictable')
        self.assertEqual(len(self.dirs('app')), 2)

    def test_out_store_keeps_the_newest_entries_within_the_count_cap(self):
        self.env['COS_TEST_KIT_OUT_MAX_ENTRIES'] = '3'
        helper = [str(self.root / 'Sources/Views.swift')]
        for i in range(6):
            self.compile(helper, flags=('-D', f'X{i}'), out=f'h{i}')
        store = self.store / 'out'
        self.assertEqual(len(list(store.glob('*.sha256'))), 3)
        self.assertEqual(len([p for p in store.iterdir() if not p.name.endswith('.sha256')]), 3)
        self.assertIn('reused', self.compile(helper, flags=('-D', 'X5'), out='again5').stderr)
        self.assertNotIn('reused', self.compile(helper, flags=('-D', 'X0'), out='again0').stderr)

    def test_out_store_byte_cap_always_keeps_the_newest(self):
        self.env['COS_TEST_KIT_OUT_MAX_BYTES'] = '1'
        helper = [str(self.root / 'Sources/Views.swift')]
        for i in range(3):
            self.compile(helper, flags=('-D', f'X{i}'), out=f'h{i}')
        self.assertEqual(len(list((self.store / 'out').glob('*.sha256'))), 1)
        self.assertIn('reused', self.compile(helper, flags=('-D', 'X2'), out='again').stderr)

    def test_out_store_sweeps_a_half_written_pair(self):
        helper = [str(self.root / 'Sources/Views.swift')]
        self.compile(helper, flags=('-D', 'X0'), out='h0')
        (self.store / 'out' / ('a' * 64)).write_text('interrupted copy')
        (self.store / 'out' / ('b' * 64 + '.sha256')).write_text('orphan receipt')
        self.compile(helper, flags=('-D', 'X1'), out='h1')
        self.assertFalse((self.store / 'out' / ('a' * 64)).exists())
        self.assertFalse((self.store / 'out' / ('b' * 64 + '.sha256')).exists())

    def test_racing_processes_cannot_corrupt_the_store(self):
        env = dict(self.env, FAKE_SLEEP='0.4', FAKE_SLEEP_HARNESS='0.3')
        for round_ in range(3):
            procs = [self.start(self.app(), env=env, flags=('-parse-as-library', '-D', f'V{i % 3}'), out=f'race{round_}-{i}')
                     for i in range(6)]
            results = [p.communicate(timeout=120) + (p.returncode,) for p in procs]
            for out, err, code in results:
                self.assertEqual(code, 0, err)
                self.assertNotIn('changed underneath', err)
            self.assertEqual([p.name for p in self.store.glob('.*-building.*')], [])
            for kit in self.dirs('app'):
                receipt = json.loads((kit / 'receipt.json').read_text())
                self.assertEqual(sorted(receipt['files']), sorted(str(p.relative_to(kit)) for p in kit.rglob('*')
                                                                   if p.is_file() and p.name != 'receipt.json'))
                for rel, sha in receipt['files'].items():
                    self.assertEqual(hashlib.sha256((kit / rel).read_bytes()).hexdigest(), sha)
        same = [self.start(self.app(), env=dict(env, FAKE_SLEEP='0.5'), out=f'same{i}') for i in range(5)]
        self.assertEqual([p.communicate(timeout=120) and p.returncode for p in same], [0] * 5)
        built_default = [c for c in self.kit_builds() if '-D' not in c]
        self.assertEqual(len(built_default), 1, 'five processes with one key must build the kit exactly once')

    def test_a_store_in_a_synced_or_relative_place_is_refused(self):
        home = self.root / 'home'
        self.env['HOME'] = str(home)
        places = [home / 'Documents/cos-kits', home / 'Desktop/cos-kits', home / 'Library/Mobile Documents/com~apple~CloudDocs/kits',
                  home / 'Documents/inner/../cos-kits']
        for i, place in enumerate(places):
            with self.subTest(place=str(place)):
                self.env['COS_TEST_KIT_STORE'] = str(place)
                self.env['COS_TEST_KIT_DIR'] = str(self.root / f'fallback{i}')
                r = self.compile(self.app())
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('iCloud', r.stderr)
                self.assertFalse(place.exists())
                self.assertEqual(len(self.dirs('app', self.root / f'fallback{i}')), 1)
        link = self.root / 'looks-fine'
        (home / 'Documents').mkdir(parents=True, exist_ok=True)
        link.symlink_to(home / 'Documents')
        self.env['COS_TEST_KIT_STORE'] = str(link / 'kits')
        self.env['COS_TEST_KIT_DIR'] = str(self.root / 'fallback-link')
        self.assertIn('iCloud', self.compile(self.app()).stderr)
        self.env['COS_TEST_KIT_STORE'] = 'relative-store'
        self.assertIn('absolute', self.compile(self.app()).stderr)
        good = home / 'Library/Caches/COS/kits/abc123'
        self.env['COS_TEST_KIT_STORE'] = str(good)
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertEqual(len(self.dirs('app', good)), 1)
        self.assertEqual(oct(good.stat().st_mode & 0o777), '0o700')

    def test_a_run_without_a_per_run_kit_dir_still_keeps_the_store(self):
        del self.env['COS_TEST_KIT_DIR']
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertEqual(len(self.dirs('app')), 1)
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertEqual(len(self.kit_builds()), 1)
        helper = [str(self.root / 'Sources/Views.swift')]
        self.compile(helper, flags=(), out='p1')
        self.assertIn('reused', self.compile(helper, flags=(), out='p2').stderr)

    def test_reusing_a_kit_refreshes_its_recency_for_eviction(self):
        for i in (0, 1):
            self.version(i)
            self.compile(self.app())
        self.version(0)
        self.compile(self.app())  # reuse of the OLDER kit
        self.assertEqual(len(self.kit_builds()), 2)
        self.version(2)
        self.compile(self.app())
        kept = {(d / 'obj/Models.o').read_text() for d in self.dirs('app')}
        self.assertEqual(kept, {'object of // version 0', 'object of // version 2'})

    def test_rebuilding_a_tampered_kit_waits_for_lanes_linking_against_it(self):
        slow = self.start(self.app(), env=dict(self.env, FAKE_SLEEP_HARNESS='3'), out='slow')
        deadline = time.time() + 20
        while time.time() < deadline and not [c for c in self.calls() if '-emit-module' not in c]:
            time.sleep(0.05)
        (kit,) = self.dirs('app')
        (kit / 'obj/Models.o').write_text('tampered')
        second = self.start(self.app(), out='second')
        time.sleep(1.0)
        self.assertIsNone(second.poll(), 'the rebuild must wait for the lane still linking against the old copy')
        self.assertTrue(kit.is_dir())
        self.assertEqual(slow.communicate(timeout=30)[0:0] or slow.returncode, 0)
        out, err = second.communicate(timeout=30)
        self.assertEqual(second.returncode, 0, err)
        self.assertEqual((kit / 'obj/Models.o').read_text(), 'object of // Models.swift')

    def test_lanes_on_one_kit_link_at_the_same_time(self):
        env = dict(self.env, FAKE_SLEEP='0.2', FAKE_SLEEP_HARNESS='2')
        procs = [self.start(self.app(), env=env, out=f'par{i}') for i in range(4)]
        self.assertEqual([p.communicate(timeout=60) and p.returncode for p in procs], [0] * 4)
        starts = sorted(json.loads(line)['at'] for line in self.log.read_text().splitlines() if '-emit-module' not in line)
        self.assertEqual(len(starts), 4)
        self.assertLess(starts[-1] - starts[0], 1.2, 'lanes linking one kit waited for each other: ' + str(starts))
        self.assertEqual(len(self.kit_builds()), 1)

    def test_a_dead_build_directory_is_swept_by_the_next_build(self):
        self.store.mkdir()
        dead = self.store / '.app-building.zzzz'
        (dead / 'obj').mkdir(parents=True)
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertFalse(dead.exists())

    def test_a_stale_use_lock_for_an_evicted_kit_is_removed(self):
        (self.store / '.use').mkdir(parents=True)
        stale = self.store / '.use' / ('app-' + '0' * 16 + '.lock')
        stale.write_text('')
        self.assertEqual(self.compile(self.app()).returncode, 0)
        self.assertFalse(stale.exists())


if __name__ == '__main__':
    unittest.main()
