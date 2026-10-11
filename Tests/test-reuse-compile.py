#!/usr/bin/env python3
"""Behavioral receipt invalidation checks, using a stand-in compiler."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('reuse-compile.py')


class ReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for directory in ('Sources', 'Tests', 'bin'):
            (self.root / directory).mkdir()
        (self.root / 'Sources/a.swift').write_text('source')
        (self.root / 'Tests/fixture.json').write_text('{}')
        (self.root / 'Package.resolved').write_text('dependency')
        self.script('Tests/compile-guard.sh', '#!/bin/sh\nexec "$@"\n')
        self.script('bin/xcrun', '#!/bin/sh\nprintf sdk-test\n')
        self.script('bin/compiler', '''#!/usr/bin/env python3
import pathlib,sys
if '--version' in sys.argv:
    print('compiler-test-1')
else:
    path=pathlib.Path('count')
    path.write_text(str(int(path.read_text())+1) if path.exists() else '1')
    pathlib.Path('app').write_text('binary')
''')
        self.env = dict(os.environ, PATH=str(self.root/'bin')+os.pathsep+os.environ['PATH'])
        self.command = [sys.executable, str(SCRIPT), '--root', str(self.root),
                        '--receipt', str(self.root/'receipt.json'), '--output', str(self.root/'app'), '--',
                        str(self.root/'Tests/compile-guard.sh'), 'compiler']

    def tearDown(self):
        self.temp.cleanup()

    def script(self, name, content):
        path = self.root/name
        path.write_text(content)
        path.chmod(0o700)

    def run_compile(self, flags=()):
        return subprocess.run(self.command+list(flags), cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def test_exact_reuse_and_each_input_invalidation(self):
        self.assertEqual(self.run_compile().returncode, 0)
        self.assertIn('verified', self.run_compile().stdout)
        self.assertEqual((self.root/'count').read_text(), '1')
        for index, path in enumerate(('Sources/a.swift', 'Tests/fixture.json', 'Package.resolved'), 2):
            (self.root/path).write_text('changed')
            self.assertEqual(self.run_compile().returncode, 0)
            self.assertEqual((self.root/'count').read_text(), str(index))
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual((self.root/'count').read_text(), '5')
        self.env['COS_TEST_COMPILER_MODE'] = 'different'
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual((self.root/'count').read_text(), '6')
        (self.root/'app').write_text('tampered')
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual((self.root/'count').read_text(), '7')
        compiler=self.root/'bin/compiler'
        compiler.write_text(compiler.read_text().replace('compiler-test-1','compiler-test-2'))
        self.assertEqual(self.run_compile(['-flag']).returncode, 0)
        self.assertEqual((self.root/'count').read_text(), '8')

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
        self.command[-2]=str(self.root/'bin/compiler')
        self.assertEqual(self.run_compile().returncode, 2)


if __name__ == '__main__':
    unittest.main()
