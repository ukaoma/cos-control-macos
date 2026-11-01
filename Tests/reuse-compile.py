#!/usr/bin/env python3
"""Reuse one successful guarded compile only when all declared inputs match.

The receipt is local to this test run, and with the persistent store OFF (the default) this script behaves exactly as it always
did: the fingerprint covers Sources, HelperSources, Tests, scripts, Resources, Package.swift, Package.resolved, the whole
environment, the command and the working directory. A changed source during compilation invalidates the result.

With the persistent store on (COS_TEST_KIT_PERSIST=1 AND COS_TEST_KIT_STORE, both set by Tests/run.sh itself; the rules and the
refusals are in Tests/kit-compile.py) the finished binary and its receipt are ALSO kept in <store>/reuse/, so the next run, in a
new scratch directory, restores the binary instead of compiling. Only then is the NARROWER fingerprint used: Sources,
HelperSources, Resources, Package.swift, Package.resolved, every file the command names (other than its guard and its own output),
the toolchain with SDK path, version and build and the host macOS build, compile-guard.sh, compile-bounded.py and this script, an
allowlist of environment keys (ENV_ALLOW), and the command with the per-run scratch directory (the --output and --receipt
parents, or /tmp/cos-control-tests.*) masked. Other Tests/ files are not inputs: a harness edit cannot change the app build.
Persistence is refused, falling back to the exact behavior above, when the environment sets SWIFT_DRIVER_*_EXEC, DYLD_* or
C_INCLUDE_PATH, or CPATH or LIBRARY_PATH to anything but the /usr/local defaults /usr/bin/python3 itself injects, when the command passes -I, -F, -L, -sdk, -Xcc or a directory to -Xlinker, or when the store is
unusable or low on disk. A cache write that fails never fails a compile that succeeded.
  COS_TEST_KIT_REUSE_MAX_ENTRIES / COS_TEST_KIT_REUSE_MAX_BYTES   store caps (default 8 binaries or 2 GiB, newest kept).
  COS_TEST_KIT_MIN_FREE_BYTES                                     free disk needed to persist (default 3 GiB).
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
UNSAFE_ENV = re.compile(r'^(SWIFT_DRIVER_.*_EXEC|DYLD_.*)$')  # change what a compile reads, and nothing hashes it
# Search paths: refused when set, EXCEPT to the one value /usr/bin/python3 (the CLT shim) puts in every process it starts.
SEARCH_ENV = {'CPATH': '/usr/local/include', 'C_INCLUDE_PATH': None, 'LIBRARY_PATH': '/usr/local/lib'}
SYNCED = (('Documents',), ('Desktop',))  # under HOME; Mobile Documents and CloudStorage are caught by CLOUD_PARTS anywhere
CLOUD_PARTS = {'mobile documents', 'cloudstorage', 'com~apple~clouddocs'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def say(text):
    print('reuse-compile: ' + text, file=sys.stderr, flush=True)


def synced_place(real):
    """True when this (resolved) path is, or sits under, a folder iCloud syncs. Case-insensitive: macOS volumes are."""
    if any(part.casefold() in CLOUD_PARTS for part in real.parts):
        return True
    home = Path(os.path.realpath(Path.home()))
    folded = str(real).casefold()
    for parts in SYNCED:
        name = str(home.joinpath(*parts)).casefold()
        if folded == name or folded.startswith(name + os.sep):
            return True
    return False


def command_blocker(args):
    """Why a command with an unhashed search path or directory may not be cached across runs, or None."""
    for i, a in enumerate(args):
        if a in ('-I', '-F', '-L', '-sdk', '-Xcc') or (len(a) > 2 and a[:2] in ('-I', '-F', '-L')):
            return a
        if a == '-Xlinker' and i + 1 < len(args) and os.path.isdir(args[i + 1]):
            return '-Xlinker <directory>'
    return None


def persistent_store(command=()):
    """The usable persistent store directory, or None (then this script is exactly the per-run tool it always was)."""
    raw = os.environ.get('COS_TEST_KIT_STORE')
    if os.environ.get('COS_TEST_KIT_PERSIST') != '1' or not raw:
        return None
    blocker = command_blocker(command[2:])
    if blocker:
        say(f'{blocker} is not hashed; nothing persists for this command')
        return None
    unsafe = sorted([k for k in os.environ if UNSAFE_ENV.match(k)]
                    + [k for k, ok in SEARCH_ENV.items() if k in os.environ and os.environ[k] != ok])
    if unsafe:
        say(f'{", ".join(unsafe)} changes what a compile reads and is not hashed; nothing persists')
        return None
    if not os.path.isabs(raw):
        say('COS_TEST_KIT_STORE must be an absolute path; nothing persists')
        return None
    real = Path(os.path.realpath(raw))
    if synced_place(real):
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


def legacy_fingerprint(root, command, toolchain):
    """The fingerprint exactly as it was before the persistent store existed (persistence off)."""
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
        try:
            shutil.copy2(output, temporary)
            os.replace(temporary, self.dir / (fp + '.bin'))
            write_json(self.dir / (fp + '.json'), dict(output=output_digest, name=output.name))
            self.trim()
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            (self.dir / (fp + '.bin')).unlink(missing_ok=True)
            (self.dir / (fp + '.json')).unlink(missing_ok=True)
            raise

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


def claim_store(base, root):
    """Record which worktree owns this store and that it is in use now (the .origin mtime is its last use)."""
    origin = base / '.origin'
    try:
        os.utime(origin)
    except FileNotFoundError:
        fd, temporary = tempfile.mkstemp(dir=base, prefix='.origin-')
        with os.fdopen(fd, 'w') as stream:
            json.dump(dict(worktree=str(root)), stream)
        os.replace(temporary, origin)


def usable(base, root):
    """The store only if it can be created and written with room to spare; otherwise None and nothing persists."""
    if base is None:
        return None
    try:
        os.makedirs(base / 'reuse', mode=0o700, exist_ok=True)
        if shutil.disk_usage(base).free < env_number('COS_TEST_KIT_MIN_FREE_BYTES', 3 << 30):
            raise OSError('not enough free disk')
        claim_store(base, root)
        return base
    except OSError as error:
        say(f'persistent store unusable ({error}); nothing persists')
        return None


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
    base = usable(persistent_store(command), root)
    toolchain = [compiler, digest(Path(compiler)),
                 subprocess.check_output([compiler, '--version'], text=True),
                 subprocess.check_output(['xcrun', '--show-sdk-path'], text=True),
                 subprocess.check_output(['xcrun', '--show-sdk-version'], text=True)]
    if base is None:
        def fingerprint_now():
            return legacy_fingerprint(root, command, toolchain)
    else:
        toolchain += [subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True),
                      subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()]
        scratch = scratch_dirs(root, args.output, args.receipt)

        def fingerprint_now():
            return fingerprint(root, command, toolchain, args.output, scratch)
    before = fingerprint_now()
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
    if base is not None:
        try:
            with Store(base) as store:
                restored = store.restore(before, args.output)
        except OSError as error:
            say(f'could not read the persistent store ({error})')
            restored = None
        if restored:
            write_json(args.receipt, dict(input=before, output=restored))
            print('compile reuse: restored from the persistent store; exact inputs and output verified')
            return 0
    result = subprocess.run(command)
    if result.returncode:
        return result.returncode
    if fingerprint_now() != before:
        print('compile inputs changed during build; result is unqualified', file=sys.stderr)
        return 1
    if not args.output.is_file():
        print('compile did not produce expected output', file=sys.stderr)
        return 1
    built = digest(args.output)
    write_json(args.receipt, dict(input=before, output=built))
    if base is not None:
        try:
            with Store(base) as store:
                store.save(before, args.output, built)
        except (OSError, shutil.Error) as error:  # the compile succeeded: a failed cache write must not fail the lane
            say(f'could not keep {args.output.name} for reuse ({error}); this run keeps its own output')
    return 0


if __name__ == '__main__':
    sys.exit(main())
