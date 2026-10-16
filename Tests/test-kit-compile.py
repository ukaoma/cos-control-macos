#!/usr/bin/env python3
"""Tests/kit-compile.py against a stand-in compiler and guard: never runs Swift."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('kit-compile.py')

FAKE_SWIFTC = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ['--version']:
    print(os.environ.get('FAKE_SWIFT_VERSION', 'fake-swift-1')); sys.exit(0)
log = pathlib.Path(os.environ['FAKE_LOG'])
with log.open('a') as s:
    s.write(json.dumps({'args': args, 'cwd': os.getcwd()}) + '\n')
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


class KitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for d in ('Sources', 'Tests', 'bin', 'out', 'kits'):
            (self.root / d).mkdir()
        for name in ('Models.swift', 'Views.swift', 'ControlSetup.swift', 'ControlInstance.swift', 'COSControlApp.swift',
                     'LiveTranscript.swift', 'MeetingAskCore.swift'):
            (self.root / 'Sources' / name).write_text('// ' + name)
        (self.root / 'Tests/A.swift').write_text('// harness a')
        (self.root / 'Tests/B.swift').write_text('// harness b')
        self.exe('Tests/compile-guard.sh', '#!/bin/sh\nexec "$@"\n')
        self.exe('bin/swiftc', FAKE_SWIFTC)
        self.exe('bin/xcrun', '#!/bin/sh\necho sdk\n')
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                        FAKE_LOG=str(self.log), COS_TEST_KIT_DIR=str(self.root / 'kits'))
        for key in ('COS_TEST_KIT', 'COS_TEST_KIT_LOG', 'FAKE_FAIL', 'FAKE_TOUCH', 'FAKE_TOUCH_ANY'):
            self.env.pop(key, None)

    def tearDown(self):
        self.temp.cleanup()

    def exe(self, rel, text):
        (self.root / rel).write_text(text)
        (self.root / rel).chmod(0o755)

    def app(self, core=False):
        skip = {'COSControlApp.swift'} | ({'ControlSetup.swift', 'ControlInstance.swift'} if core else set())
        return [str(p) for p in sorted((self.root / 'Sources').glob('*.swift')) if p.name not in skip]

    def compile(self, sources, harness=('Tests/A.swift',), flags=('-parse-as-library',), out='lane', extra=()):
        command = [sys.executable, str(SCRIPT), str(self.root / 'Tests/compile-guard.sh'), 'swiftc',
                   '-target', 'arm64-apple-macosx14.0', '-swift-version', '6', '-strict-concurrency=complete', *flags,
                   *sources, *[str(self.root / h) for h in harness], '-framework', 'AppKit', *extra,
                   '-o', str(self.root / 'out' / out)]
        return subprocess.run(command, env=self.env, cwd=self.root, capture_output=True, text=True)

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line)['args'] for line in self.log.read_text().splitlines()]

    def kit_builds(self):
        return [c for c in self.calls() if '-emit-module' in c]

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

    def test_old_kits_are_evicted(self):
        models = self.root / 'Sources/Models.swift'
        for i in range(7):
            models.write_text(f'// version {i}')
            self.compile(self.app())
        self.assertEqual(len(list((self.root / 'kits').glob('app-*'))), 4)


if __name__ == '__main__':
    unittest.main()
