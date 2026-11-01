#!/usr/bin/env python3
"""Reuse one successful guarded compile only when all declared inputs match.

The receipt is local to this test run. With the persistent store on (COS_TEST_KIT_PERSIST=1 AND COS_TEST_KIT_STORE, both set by
Tests/run.sh itself; the rules are in Tests/kit-compile.py) the finished binary and its receipt are ALSO kept in <store>/reuse/, so the
next run, in a new scratch directory, restores the binary instead of compiling. Off (the default) it is the per-run receipt only.
Environment values are hashed, never written, and only an allowlist of them (ENV_ALLOW): a session variable cannot change a key.
Changed source during compilation invalidates the result.

Declared inputs: Sources, HelperSources, Resources, Package.swift, Package.resolved, every file the command names (other than its guard
and its own output), the toolchain with SDK path, version and build, compile-guard.sh, compile-bounded.py and this script. Other
Tests/ files are NOT inputs: a harness edit cannot change the app build, so it must not force a recompile of it. The per-run scratch
directory (the --output and --receipt parents, or /tmp/cos-control-tests.*) is masked out of the command and the working directory.
  COS_TEST_KIT_REUSE_MAX_ENTRIES / COS_TEST_KIT_REUSE_MAX_BYTES   store caps (default 8 binaries or 2 GiB, newest kept).
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')
INPUT_FILES = ('Package.swift', 'Package.resolved')
ENV_ALLOW = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET', 'SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH')
RUN_TMP = re.compile(r'(?:/private)?/tmp/cos-control-tests\.[A-Za-z0-9_]+')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def say(text):
    print('reuse-compile: ' + text, file=sys.stderr, flush=True)


def persistent_store():
    """Same rules as kit-compile.py: both variables, an absolute path, never an iCloud-synced folder."""
    raw = os.environ.get('COS_TEST_KIT_STORE')
    if os.environ.get('COS_TEST_KIT_PERSIST') != '1' or not raw:
        return None
    if not os.path.isabs(raw):
        say('COS_TEST_KIT_STORE must be an absolute path; nothing persists')
        return None
    real = Path(os.path.realpath(raw))
    home = Path(os.path.realpath(Path.home()))
    synced = [home / 'Documents', home / 'Desktop', home / 'Library' / 'Mobile Documents']
    if 'Mobile Documents' in real.parts or any(real == s or s in real.parents for s in synced):
        say('COS_TEST_KIT_STORE is in an iCloud-synced folder; nothing persists')
        return None
    return real


def env_number(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def scratch_dirs(root, output, receipt):
    """The per-run directories this call was handed (never the checkout, never a shallow system directory)."""
    found = set()
    for path in (output, receipt):
        for form in (path.parent, path.resolve().parent):
            parts = Path(os.path.abspath(form)).parts
            if len(parts) >= 3 and form.resolve() != root and form.resolve() not in root.parents:
                found.add(str(form))
    return sorted(found, key=len, reverse=True)


def mask(text, scratch):
    for directory in scratch:
        text = text.replace(directory, '<tmp>')
    return RUN_TMP.sub('<tmp>', text)


def named_files(command, output, scratch):
    """Files the command itself names (a generated source, a Tests/ harness) except the guard and the output."""
    found = []
    for item in command[1:]:
        path = Path(item)
        if path.is_file() and path.resolve() != output.resolve():
            found.append((mask(str(path), scratch), digest(path)))
    return found


def tool_digests(command):
    guard = Path(command[0])
    bounded = guard.with_name('compile-bounded.py')
    return {'reuse-compile': digest(Path(__file__)),
            'compile-guard': digest(guard) if guard.is_file() else None,
            'compile-bounded': digest(bounded) if bounded.is_file() else None}


def fingerprint(root, command, toolchain, output, scratch):
    files = []
    for name in INPUT_DIRS + INPUT_FILES:
        path = root / name
        candidates = sorted(path.rglob('*')) if path.is_dir() else [path]
        for item in candidates:
            if item.is_file() and '__pycache__' not in item.parts:
                files.append((str(item.relative_to(root)), digest(item)))
    env = [(key, os.environ.get(key)) for key in ENV_ALLOW]
    material = dict(files=files, named=named_files(command, output, scratch), tools=sorted(tool_digests(command).items()),
                    command=[mask(item, scratch) for item in command], toolchain=toolchain, env=env,
                    cwd=mask(os.getcwd(), scratch))
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    with os.fdopen(fd, 'w') as stream:
        json.dump(data, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


class Store:
    """<store>/reuse/<fingerprint>.bin plus <fingerprint>.json; one exclusive lock around every read, write and trim."""

    def __init__(self, base):
        self.dir = base / 'reuse'
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        self.lock_fd = os.open(self.dir / '.lock', os.O_CREAT | os.O_RDWR, 0o600)

    def __enter__(self):
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
        os.close(self.lock_fd)

    def restore(self, fp, output):
        binary, meta = self.dir / (fp + '.bin'), self.dir / (fp + '.json')
        try:
            want = json.loads(meta.read_text())['output']
            if digest(binary) != want:
                return None
            output.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(dir=output.parent, prefix='.restore-')
            os.close(fd)
            shutil.copy2(binary, temporary)
            if digest(Path(temporary)) != want:
                os.unlink(temporary)
                return None
            os.replace(temporary, output)
            os.utime(binary)
            return want
        except (OSError, ValueError, KeyError):
            return None

    def save(self, fp, output, output_digest):
        fd, temporary = tempfile.mkstemp(dir=self.dir, prefix='.save-')
        os.close(fd)
        shutil.copy2(output, temporary)
        os.replace(temporary, self.dir / (fp + '.bin'))
        write_json(self.dir / (fp + '.json'), dict(output=output_digest, name=output.name))
        self.trim()

    def trim(self):
        """Newest binaries up to the count or byte cap, whichever first (the newest always stays); half-written pairs go."""
        limit_entries = env_number('COS_TEST_KIT_REUSE_MAX_ENTRIES', 8)
        limit_bytes = env_number('COS_TEST_KIT_REUSE_MAX_BYTES', 2 << 30)
        entries = {}
        for p in self.dir.iterdir():
            if p.name != '.lock':
                entries.setdefault(p.name.rsplit('.', 1)[0], []).append(p)
        whole = []
        for stem, files in entries.items():
            if len(files) == 2 and (self.dir / (stem + '.bin')).is_file() and (self.dir / (stem + '.json')).is_file():
                whole.append((max(f.stat().st_mtime for f in files), stem))
            else:
                for f in files:
                    f.unlink(missing_ok=True)
        count = total = 0
        over = False
        for _, stem in sorted(whole, reverse=True):
            size = (self.dir / (stem + '.bin')).stat().st_size
            if count and (count + 1 > limit_entries or total + size > limit_bytes):
                over = True
            if over:
                (self.dir / (stem + '.bin')).unlink(missing_ok=True)
                (self.dir / (stem + '.json')).unlink(missing_ok=True)
            else:
                count += 1
                total += size


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
                 subprocess.check_output(['xcrun', '--show-sdk-version'], text=True),
                 subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True)]
    scratch = scratch_dirs(root, args.output, args.receipt)
    before = fingerprint(root, command, toolchain, args.output, scratch)
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
    base = persistent_store()
    if base is not None:
        with Store(base) as store:
            restored = store.restore(before, args.output)
        if restored:
            write_json(args.receipt, dict(input=before, output=restored))
            print('compile reuse: restored from the persistent store; exact inputs and output verified')
            return 0
    result = subprocess.run(command)
    if result.returncode:
        return result.returncode
    if fingerprint(root, command, toolchain, args.output, scratch) != before:
        print('compile inputs changed during build; result is unqualified', file=sys.stderr)
        return 1
    if not args.output.is_file():
        print('compile did not produce expected output', file=sys.stderr)
        return 1
    built = digest(args.output)
    write_json(args.receipt, dict(input=before, output=built))
    if base is not None:
        with Store(base) as store:
            store.save(before, args.output, built)
    return 0


if __name__ == '__main__':
    sys.exit(main())
