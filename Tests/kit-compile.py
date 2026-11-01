#!/usr/bin/env python3
"""Compile a lane's test harness against ONE shared build of the app sources.

    python3 Tests/kit-compile.py [zsh] <checkout>/Tests/compile-guard.sh swiftc <the lane's own swiftc arguments>

Until 0.5.317 every lane compiled Sources/*.swift (45 files, about 71K lines) again together with its one harness file,
about 40 full compiles a suite (69 minutes for 0.5.315). This wrapper takes the lane's command exactly as it was
written. When the Sources files in it are one of the KITS below and the rest is a plain executable build, the Sources are
compiled ONCE per suite into the module COSControlKit (objects plus a testable module, with the lane's own compiler
flags plus -enable-testing), and the lane compiles only its harness against that module: the harness files get an
implicit `@testable import COSControlKit` (so internal names resolve as they did in one module; private and fileprivate
stay invisible, as they always were across files) and the link takes every kit object, as the one-module build did.
Every compile still goes through Tests/compile-guard.sh, the shared kit build included. Anything else runs exactly as
written; a command repeated byte for byte with the same inputs (the helper, built by three lanes) reuses the first
binary when COS_TEST_KIT_DIR is set.

  COS_TEST_KIT=0       run every command exactly as written (the old layout, for equivalence runs)
  COS_TEST_KIT_DIR     where kits live for this run (Tests/run.sh and the mutation runners set it). Unset: a private
                       directory removed on exit, so a lane run alone still builds the same way, with nothing reused.
  COS_TEST_KIT_LOG     append one JSON line per call (mode, kit, seconds, persist) for timing receipts

  Persistent store (opt-in, default OFF; Tests/run.sh turns it on for its own process tree and nothing else does):
  COS_TEST_KIT_PERSIST=1  required. Unset, 0 or anything else gives the layout above exactly, and an exported
                       COS_TEST_KIT_STORE alone is IGNORED, so a stray session or a mutation runner never shares a store.
  COS_TEST_KIT_STORE   absolute directory (run.sh: ~/Library/Caches/COS/kits/<hash of the worktree realpath>). Kits and
                       the exact-reuse out/ store live there across runs instead of COS_TEST_KIT_DIR. Refused (the run
                       falls back to the per-run layout) under ~/Documents, ~/Desktop or Mobile Documents: iCloud syncs those.
  COS_TEST_KIT_EVICT_MIN_AGE        seconds a kit must be idle before eviction may remove it (default 7200, longer than
                       a suite, so one run can never evict kits it is still using).
  COS_TEST_KIT_OUT_MAX_ENTRIES / COS_TEST_KIT_OUT_MAX_BYTES   out/ caps (default 40 entries or 2 GiB, newest kept).
  The store keeps the newest 2 keys per kit NAME. A process holds a shared lock on its kit (.use/<kit>.lock) from the
  build through the link; eviction removes a kit only after it takes that lock exclusively, without waiting.

A kit is reused only when its receipt matches the exact source bytes, the flags, the toolchain and the SDK, and every
object still has the digest the build recorded. A source that changes while the kit compiles invalidates the result.
The key also carries this script's own digest, compile-guard.sh's, compile-bounded.py's and the SDK build version.
"""
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
import time

MODULE = 'COSControlKit'
# Bump when the build recipe below changes, so an older receipt can never be read as this one's.
RECIPE = 2
# Kits by Sources file names. A lane uses a kit only when its Sources files are EXACTLY one of these sets.
APP_EXCLUDED = {'COSControlApp.swift'}           # the shipped @main; every lane replaces it with its own


def kit_sets(src_dir):
    every = sorted(p.name for p in src_dir.glob('*.swift'))
    app = [n for n in every if n not in APP_EXCLUDED]
    return {
        'app': app,
        # The render harnesses (Held, Merge, Markdown, Pet composer, Jedi idle) predate ControlSetup and ControlInstance.
        'app-core': [n for n in app if n not in ('ControlSetup.swift', 'ControlInstance.swift')],
        'meeting-core': ['LiveTranscript.swift', 'MeetingAskCore.swift', 'Models.swift'],
        'models': ['Models.swift'],
        # Compiled alone by about eight lanes (voice style, edit confirm, edit capture, dictation parity, ...).
        'mac-dictation-core': ['MacDictationCore.swift'],
    }


PAIRED_COMPILE = {'-target', '-swift-version', '-sdk', '-module-cache-path', '-D', '-I', '-F', '-Xcc'}
SINGLE_COMPILE = {'-parse-as-library', '-Onone', '-O', '-Osize', '-g', '-warnings-as-errors', '-enable-testing'}
PAIRED_LINK = {'-framework', '-weak-framework', '-Xlinker', '-L', '-l'}
ENV_KEYS = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS')
KEEP_KITS = 4                                     # per-run layout: newest 4 across all names (as before)
KEEP_PER_NAME = 2                                 # persistent store: newest 2 keys per kit name
KIT_DIR = re.compile(r'^(.+)-[0-9a-f]{16}$')
# The per-run scratch Tests/run.sh makes (mktemp -d /tmp/cos-control-tests.XXXXXX): never part of an output key.
RUN_TMP = re.compile(r'(?:/private)?/tmp/cos-control-tests\.[A-Za-z0-9_]+')


def log(record):
    target = os.environ.get('COS_TEST_KIT_LOG')
    if target:
        with open(target, 'a') as stream:
            stream.write(json.dumps(record, sort_keys=True) + '\n')


def say(text):
    print('kit-compile: ' + text, file=sys.stderr, flush=True)


def digest_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def split_prefix(argv):
    """[zsh] <...>/compile-guard.sh swiftc args -> (prefix through swiftc, args)."""
    i = 0
    if argv and Path(argv[0]).name in ('zsh', 'sh', 'bash') and len(argv) > 1 and argv[1].endswith('compile-guard.sh'):
        i = 1
    if len(argv) < i + 2 or Path(argv[i]).name != 'compile-guard.sh' or Path(argv[i + 1]).name != 'swiftc':
        raise SystemExit('kit-compile: usage: kit-compile.py [zsh] <checkout>/Tests/compile-guard.sh swiftc <arguments>')
    return argv[:i + 2], argv[i + 2:]


def parse(args):
    """A plain executable build, or None (then the command runs exactly as written)."""
    compile_opts, link_opts, swift, output = [], [], [], None
    i = 0
    while i < len(args):
        a = args[i]
        if a in PAIRED_COMPILE or a in PAIRED_LINK or a == '-o':
            if i + 1 >= len(args):
                return None
            value = args[i + 1]
            if a == '-o':
                if output is not None:
                    return None
                output = value
            else:
                (compile_opts if a in PAIRED_COMPILE else link_opts).extend([a, value])
            i += 2
            continue
        if a in SINGLE_COMPILE or a.startswith('-strict-concurrency='):
            compile_opts.append(a)
        elif a.endswith('.swift') and not a.startswith('-'):
            swift.append(a)
        else:
            return None  # -typecheck, -c, -emit-*, -module-name, anything unrecognised: not ours to restructure
        i += 1
    if output is None or not swift:
        return None
    # Two or more inputs with none named main.swift are library files already: -parse-as-library changes nothing for
    # them. Say so explicitly, because the harness alone is ONE file, which the driver would read as a script.
    if '-parse-as-library' not in compile_opts and len(swift) >= 2 and not any(Path(s).name == 'main.swift' for s in swift):
        compile_opts = compile_opts + ['-parse-as-library']
    return dict(compile=compile_opts, link=link_opts, swift=swift, output=output)


def persistent_store():
    """The persistent store directory, or None. Needs COS_TEST_KIT_PERSIST=1 (run.sh sets it) AND COS_TEST_KIT_STORE."""
    raw = os.environ.get('COS_TEST_KIT_STORE')
    if os.environ.get('COS_TEST_KIT_PERSIST') != '1' or not raw:
        return None
    if not os.path.isabs(raw):
        say('COS_TEST_KIT_STORE must be an absolute path; kits stay per-run')
        return None
    real = Path(os.path.realpath(raw))
    home = Path(os.path.realpath(Path.home()))
    synced = [home / 'Documents', home / 'Desktop', home / 'Library' / 'Mobile Documents']
    if 'Mobile Documents' in real.parts or any(real == s or s in real.parents for s in synced):
        say('COS_TEST_KIT_STORE is in an iCloud-synced folder; kits stay per-run')
        return None
    return real


def tool_digests(prefix):
    """This script and the guard scripts: a change to any of them changes what a kit or output means."""
    guard = Path(prefix[-2])
    bounded = guard.with_name('compile-bounded.py')
    return {'kit-compile': digest_file(__file__),
            'compile-guard': digest_file(guard) if guard.is_file() else None,
            'compile-bounded': digest_file(bounded) if bounded.is_file() else None}


def toolchain(prefix):
    compiler = prefix[-1]
    path = shutil.which(compiler)
    if not path:
        raise SystemExit('kit-compile: ' + compiler + ' not found')
    real = os.path.realpath(path)
    st = os.stat(real)
    version = subprocess.run([path, '--version'], capture_output=True, text=True).stdout
    sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    sdk_version = subprocess.run(['xcrun', '--show-sdk-version'], capture_output=True, text=True).stdout.strip()
    sdk_build = subprocess.run(['xcrun', '--show-sdk-build-version'], capture_output=True, text=True).stdout.strip()
    return [path, real, st.st_size, st.st_mtime_ns, version, sdk, sdk_version,
            [(k, os.environ.get(k)) for k in ENV_KEYS], sdk_build, sorted(tool_digests(prefix).items())]


def match_kit(parsed):
    """(kit name, Sources dir, kit files, harness files) or None."""
    kit_files = [s for s in parsed['swift'] if Path(s).parent.name == 'Sources']
    harness = [s for s in parsed['swift'] if Path(s).parent.name != 'Sources']
    if not kit_files or not harness or '-parse-as-library' not in parsed['compile']:
        return None
    dirs = {os.path.realpath(Path(s).parent) for s in kit_files}
    if len(dirs) != 1:
        return None
    src_dir = Path(dirs.pop())
    names = sorted(Path(s).name for s in kit_files)
    if len(set(names)) != len(names):
        return None
    for name, members in kit_sets(src_dir).items():
        if names == sorted(members):
            return name, src_dir, [src_dir / n for n in names], harness
    return None


def env_number(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


class KitRoot:
    def __init__(self):
        store = persistent_store()
        configured = os.environ.get('COS_TEST_KIT_DIR')
        self.persistent = store is not None
        self.private = not self.persistent and not configured
        if self.persistent:
            self.path = store
        else:
            self.path = Path(configured) if configured else Path(tempfile.mkdtemp(prefix='cos-test-kit.', dir='/tmp'))
        os.makedirs(self.path, mode=0o700 if self.persistent else 0o777, exist_ok=True)
        self.lock_fd = os.open(self.path / '.lock', os.O_CREAT | os.O_RDWR, 0o600)
        self.held = []

    def lock(self, exclusive):
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)

    def unlock(self):
        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)

    def close(self):
        for fd in self.held:
            os.close(fd)
        os.close(self.lock_fd)
        if self.private:
            shutil.rmtree(self.path, ignore_errors=True)

    def use_lock(self, kit_name):
        return self.path / '.use' / (kit_name + '.lock')

    def hold(self, kit_name):
        """Persistent store: a shared lock on this kit until the process ends (build through link), taken under the
        exclusive build lock so no eviction can run between the build and the link. Returns the descriptor."""
        (self.path / '.use').mkdir(exist_ok=True)
        fd = os.open(self.use_lock(kit_name), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_SH)
        self.held.append(fd)
        return fd

    def evict(self, keep):
        if not self.persistent:
            kits = sorted((p for p in self.path.iterdir() if p.is_dir() and (p / 'receipt.json').exists() and p != keep),
                          key=lambda p: p.stat().st_mtime, reverse=True)
            for old in kits[KEEP_KITS - 1:]:
                shutil.rmtree(old, ignore_errors=True)
            return
        min_age = env_number('COS_TEST_KIT_EVICT_MIN_AGE', 7200)
        groups = {}
        for p in self.path.iterdir():
            m = KIT_DIR.match(p.name)
            if m and p.is_dir() and (p / 'receipt.json').exists():
                groups.setdefault(m.group(1), []).append(p)
        for kits in groups.values():
            kits.sort(key=lambda p: (p == keep, p.stat().st_mtime), reverse=True)
            for old in kits[KEEP_PER_NAME:]:
                if time.time() - old.stat().st_mtime >= min_age:
                    self.evict_unused(old)
        for stale in list(self.path.glob('.use/*.lock')):  # a lock whose kit is gone (a failed build, an earlier eviction)
            if not (self.path / stale.name[:-len('.lock')]).exists():
                self.drop_if_unused(stale)

    def drop_if_unused(self, lock_path):
        """Takes the lock exclusively WITHOUT waiting: a process still linking against the kit holds it shared."""
        try:
            fd = os.open(lock_path, os.O_RDWR)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        lock_path.unlink(missing_ok=True)
        os.close(fd)
        return True

    def evict_unused(self, kit):
        lock_path = self.use_lock(kit.name)
        try:
            fd = os.open(lock_path, os.O_RDWR)
        except FileNotFoundError:
            fd = None
        except OSError:
            return
        if fd is not None:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(fd)  # still in use by a lane that is linking against it
                return
        shutil.rmtree(kit, ignore_errors=True)
        if fd is not None:
            lock_path.unlink(missing_ok=True)
            os.close(fd)


def source_digests(files):
    return {f.name: digest_file(f) for f in files}


def kit_key(name, src_dir, digests, compile_opts, tc):
    material = dict(recipe=RECIPE, kit=name, dir=str(src_dir), sources=sorted(digests.items()),
                    flags=compile_opts, toolchain=tc)
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


def valid_receipt(kit_dir, key):
    try:
        receipt = json.loads((kit_dir / 'receipt.json').read_text())
        if receipt.get('key') != key or receipt.get('recipe') != RECIPE:
            return None
        for rel, sha in receipt['files'].items():
            if digest_file(kit_dir / rel) != sha:
                return None
        return receipt
    except (OSError, ValueError, KeyError, TypeError):
        return None


def build_kit(root, prefix, name, src_dir, files, digests, compile_opts, key):
    """Returns (kit dir, receipt, exit code). Caller holds the exclusive lock."""
    kit_dir = root.path / f'{name}-{key[:16]}'
    use = None
    if root.persistent:
        for dead in root.path.glob('.*-building.*'):  # we hold the build lock, so no live build owns these
            shutil.rmtree(dead, ignore_errors=True)
        use = root.hold(kit_dir.name)
    receipt = valid_receipt(kit_dir, key)
    if receipt:
        os.utime(kit_dir)
        return kit_dir, receipt, 0, 'reuse'
    if use is not None:
        fcntl.flock(use, fcntl.LOCK_EX)  # wait for lanes still linking against a stale copy of this very kit
    shutil.rmtree(kit_dir, ignore_errors=True)
    work = Path(tempfile.mkdtemp(prefix=f'.{name}-building.', dir=root.path))
    try:
        (work / 'obj').mkdir()
        module = work / f'{MODULE}.swiftmodule'
        command = [*prefix, *compile_opts, '-enable-testing', '-module-name', MODULE,
                   '-emit-module', '-emit-module-path', str(module), '-c', *map(str, files)]
        say(f'building shared kit "{name}" ({len(files)} files) once for this run')
        code = subprocess.run(command, cwd=work / 'obj').returncode
        if code:
            return None, None, code, 'build'
        if source_digests(files) != digests:
            say('kit sources changed during the build; the result is unqualified')
            return None, None, 1, 'build'
        objects = sorted(p.name for p in (work / 'obj').glob('*.o'))
        expected = sorted(f.stem + '.o' for f in files)
        if objects != expected or not module.is_file():
            say(f'kit build did not produce the expected outputs ({len(objects)} objects for {len(files)} files)')
            return None, None, 1, 'build'
        recorded = {f'obj/{o}': digest_file(work / 'obj' / o) for o in objects}
        recorded[module.name] = digest_file(module)
        receipt = dict(recipe=RECIPE, key=key, kit=name, sources=digests, files=recorded,
                       objects=[f'obj/{o}' for o in objects], flags=compile_opts)
        (work / 'receipt.json').write_text(json.dumps(receipt, indent=1, sort_keys=True))
        os.replace(work, kit_dir)
        if use is not None:
            fcntl.flock(use, fcntl.LOCK_SH)  # building is done; from here on this lane only reads the kit
        root.evict(kit_dir)
        return kit_dir, receipt, 0, 'build'
    finally:
        if use is not None:
            fcntl.flock(use, fcntl.LOCK_SH)  # idempotent; also covers the failure returns above
        shutil.rmtree(work, ignore_errors=True)


def run_kit(prefix, parsed, match, tc):
    name, src_dir, files, harness = match
    root = KitRoot()
    try:
        digests = source_digests(files)
        key = kit_key(name, src_dir, digests, parsed['compile'], tc)
        started = time.monotonic()
        root.lock(exclusive=True)
        try:
            kit_dir, receipt, code, how = build_kit(root, prefix, name, src_dir, files, digests, parsed['compile'], key)
        finally:
            root.unlock()
        log(dict(mode='kit-' + how, kit=name, code=code, persist=root.persistent,
                 seconds=round(time.monotonic() - started, 3)))
        if code:
            return code
        started = time.monotonic()
        # Per-run layout: a shared lock keeps every eviction out while this link reads the kit. Persistent store: the
        # use lock build_kit took (held until this process ends) does that without stalling other lanes' builds.
        if not root.persistent:
            root.lock(exclusive=False)
        try:
            if valid_receipt(kit_dir, key) is None:
                say(f'kit "{name}" changed underneath this lane')
                return 1
            objects = [x for o in receipt['objects'] for x in ('-Xlinker', str(kit_dir / o))]
            command = [*prefix, *parsed['compile'], '-I', str(kit_dir),
                       '-Xfrontend', '-testable-import-module', '-Xfrontend', MODULE,
                       *harness, *parsed['link'], *objects, '-o', parsed['output']]
            code = subprocess.run(command).returncode
        finally:
            if not root.persistent:
                root.unlock()
        log(dict(mode='harness', kit=name, output=Path(parsed['output']).name, code=code, persist=root.persistent,
                 seconds=round(time.monotonic() - started, 3)))
        return code
    finally:
        root.close()


def mask(text):
    """The per-run scratch directory is not an input: the same command in the next run's directory is the same command."""
    return RUN_TMP.sub('<tmp>', text)


def output_key(args, parsed, tc):
    inputs = []
    for a in args:
        if a != parsed['output'] and os.path.isfile(a):
            inputs.append((mask(a), digest_file(a)))
    masked = ['<output>' if a == parsed['output'] else mask(a) for a in args]
    material = dict(recipe=RECIPE, args=masked, inputs=inputs, cwd=mask(os.getcwd()), toolchain=tc)
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


def evict_out(store):
    """Persistent store only, under the exclusive build lock: newest entries up to the count or byte cap, whichever
    comes first (the newest one always stays). Also removes a half-written pair left by an interrupted copy."""
    limit_entries = env_number('COS_TEST_KIT_OUT_MAX_ENTRIES', 40)
    limit_bytes = env_number('COS_TEST_KIT_OUT_MAX_BYTES', 2 << 30)
    entries = {}
    for p in store.iterdir():
        stem = p.name[:-len('.sha256')] if p.name.endswith('.sha256') else p.name
        entries.setdefault(stem, []).append(p)
    whole = []
    for stem, files in entries.items():
        if len(files) == 2 and (store / stem).is_file():
            whole.append((max(f.stat().st_mtime for f in files), stem))
        else:
            for f in files:
                f.unlink(missing_ok=True)
    count = total = 0
    over = False
    for _, stem in sorted(whole, reverse=True):
        size = (store / stem).stat().st_size
        if count and (count + 1 > limit_entries or total + size > limit_bytes):
            over = True
        if over:
            (store / stem).unlink(missing_ok=True)
            (store / (stem + '.sha256')).unlink(missing_ok=True)
        else:
            count += 1
            total += size


def run_exact(prefix, args, parsed, tc):
    """A plain build repeated with identical inputs reuses the first binary (only when the run shares a kit dir)."""
    if parsed is None or not (persistent_store() or os.environ.get('COS_TEST_KIT_DIR')):
        return subprocess.run([*prefix, *args]).returncode
    root = KitRoot()
    try:
        store = root.path / 'out'
        store.mkdir(exist_ok=True)
        key = output_key(args, parsed, tc)
        cached, receipt = store / key, store / (key + '.sha256')
        started = time.monotonic()
        root.lock(exclusive=True)
        try:
            if cached.is_file() and receipt.is_file() and receipt.read_text() == digest_file(cached):
                out = Path(parsed['output'])
                out.unlink(missing_ok=True)
                shutil.copy2(cached, out)
                os.utime(cached)
                say(f'{out.name}: identical command and inputs already built' + ('' if root.persistent else ' this run') + '; reused')
                log(dict(mode='exact-reuse', output=out.name, persist=root.persistent,
                         seconds=round(time.monotonic() - started, 3)))
                return 0
        finally:
            root.unlock()
        code = subprocess.run([*prefix, *args]).returncode
        if code == 0 and os.path.isfile(parsed['output']) and output_key(args, parsed, tc) == key:
            root.lock(exclusive=True)
            try:
                shutil.copy2(parsed['output'], cached)
                receipt.write_text(digest_file(cached))
                if root.persistent:
                    evict_out(store)
            finally:
                root.unlock()
        log(dict(mode='exact-build', output=Path(parsed['output']).name, code=code, persist=root.persistent,
                 seconds=round(time.monotonic() - started, 3)))
        return code
    finally:
        root.close()


def main(argv):
    prefix, args = split_prefix(argv)
    if os.environ.get('COS_TEST_KIT', '1') == '0':
        os.execvp(prefix[0], [*prefix, *args])
    parsed = parse(args)
    tc = toolchain(prefix)
    match = match_kit(parsed) if parsed else None
    if match:
        return run_kit(prefix, parsed, match, tc)
    return run_exact(prefix, args, parsed, tc)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
