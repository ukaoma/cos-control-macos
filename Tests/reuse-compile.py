#!/usr/bin/env python3
"""Reuse one successful guarded compile only when all declared inputs match.

The receipt is local to this test run. Environment values are hashed, never
written. Changed source during compilation invalidates the result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(root, command, toolchain):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    root = args.root.resolve()
    if len(command) < 2 or Path(command[0]).resolve() != root / 'Tests/compile-guard.sh':
        parser.error('command must start with this checkout\'s compile-guard.sh')
    compiler = shutil.which(command[1])
    if not compiler:
        parser.error('compiler missing')
    toolchain = [compiler, digest(Path(compiler)),
                 subprocess.check_output([compiler, '--version'], text=True),
                 subprocess.check_output(['xcrun', '--show-sdk-path'], text=True),
                 subprocess.check_output(['xcrun', '--show-sdk-version'], text=True)]
    before = fingerprint(root, command, toolchain)
    try:
        prior = json.loads(args.receipt.read_text())
        if (prior['input'] == before and args.output.is_file()
                and prior['output'] == digest(args.output)):
            print('compile reuse: verified exact inputs and output')
            return 0
    except (OSError, ValueError, KeyError):
        pass
    # An unsuccessful attempt must not retain a receipt from an earlier build.
    args.receipt.unlink(missing_ok=True)
    result = subprocess.run(command)
    if result.returncode:
        return result.returncode
    if fingerprint(root, command, toolchain) != before:
        print('compile inputs changed during build; result is unqualified', file=sys.stderr)
        return 1
    if not args.output.is_file():
        print('compile did not produce expected output', file=sys.stderr)
        return 1
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=args.receipt.parent)
    with os.fdopen(fd, 'w') as stream:
        json.dump(dict(input=before, output=digest(args.output)), stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, args.receipt)
    return 0


if __name__ == '__main__':
    sys.exit(main())
