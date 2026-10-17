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
  COS_TEST_KIT_LOG     append one JSON line per call (mode, kit, seconds) for timing receipts

A kit is reused only when its receipt matches the exact source bytes, the flags, the toolchain and the SDK, and every
object still has the digest the build recorded. A source that changes while the kit compiles invalidates the result.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

MODULE = 'COSControlKit'
# Bump when the build recipe below changes, so an older receipt can never be read as this one's.
RECIPE = 1
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
    }


PAIRED_COMPILE = {'-target', '-swift-version', '-sdk', '-module-cache-path', '-D', '-I', '-F', '-Xcc'}
SINGLE_COMPILE = {'-parse-as-library', '-Onone', '-O', '-Osize', '-g', '-warnings-as-errors', '-enable-testing'}
PAIRED_LINK = {'-framework', '-weak-framework', '-Xlinker', '-L', '-l'}
ENV_KEYS = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS')
KEEP_KITS = 4


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


def toolchain(compiler):
    path = shutil.which(compiler)
    if not path:
        raise SystemExit('kit-compile: ' + compiler + ' not found')
    real = os.path.realpath(path)
    st = os.stat(real)
    version = subprocess.run([path, '--version'], capture_output=True, text=True).stdout
    sdk = subprocess.run(['xcrun', '--show-sdk-path'], capture_output=True, text=True).stdout.strip()
    sdk_version = subprocess.run(['xcrun', '--show-sdk-version'], capture_output=True, text=True).stdout.strip()
    return [path, real, st.st_size, st.st_mtime_ns, version, sdk, sdk_version,
            [(k, os.environ.get(k)) for k in ENV_KEYS]]


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


class KitRoot:
    def __init__(self):
        configured = os.environ.get('COS_TEST_KIT_DIR')
        self.private = not configured
        self.path = Path(configured) if configured else Path(tempfile.mkdtemp(prefix='cos-test-kit.', dir='/tmp'))
        self.path.mkdir(parents=True, exist_ok=True)
        self.lock_fd = os.open(self.path / '.lock', os.O_CREAT | os.O_RDWR, 0o600)

    def lock(self, exclusive):
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)

    def unlock(self):
        fcntl.flock(self.lock_fd, fcntl.LOCK_UN)

    def close(self):
        os.close(self.lock_fd)
        if self.private:
            shutil.rmtree(self.path, ignore_errors=True)

    def evict(self, keep):
        kits = sorted((p for p in self.path.iterdir() if p.is_dir() and (p / 'receipt.json').exists() and p != keep),
                      key=lambda p: p.stat().st_mtime, reverse=True)
        for old in kits[KEEP_KITS - 1:]:
            shutil.rmtree(old, ignore_errors=True)


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
    receipt = valid_receipt(kit_dir, key)
    if receipt:
        os.utime(kit_dir)
        return kit_dir, receipt, 0, 'reuse'
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
        root.evict(kit_dir)
        return kit_dir, receipt, 0, 'build'
    finally:
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
        log(dict(mode='kit-' + how, kit=name, code=code, seconds=round(time.monotonic() - started, 3)))
        if code:
            return code
        started = time.monotonic()
        root.lock(exclusive=False)  # an eviction can never remove the kit this link is reading
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
            root.unlock()
        log(dict(mode='harness', kit=name, output=Path(parsed['output']).name, code=code,
                 seconds=round(time.monotonic() - started, 3)))
        return code
    finally:
        root.close()


def output_key(args, parsed, tc):
    inputs = []
    for a in args:
        if a != parsed['output'] and os.path.isfile(a):
            inputs.append((a, digest_file(a)))
    masked = ['<output>' if a == parsed['output'] else a for a in args]
    material = dict(recipe=RECIPE, args=masked, inputs=inputs, cwd=os.getcwd(), toolchain=tc)
    return hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()


def run_exact(prefix, args, parsed, tc):
    """A plain build repeated with identical inputs reuses the first binary (only when the run shares a kit dir)."""
    if not os.environ.get('COS_TEST_KIT_DIR') or parsed is None:
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
                say(f'{out.name}: identical command and inputs already built this run; reused')
                log(dict(mode='exact-reuse', output=out.name, seconds=round(time.monotonic() - started, 3)))
                return 0
        finally:
            root.unlock()
        code = subprocess.run([*prefix, *args]).returncode
        if code == 0 and os.path.isfile(parsed['output']) and output_key(args, parsed, tc) == key:
            root.lock(exclusive=True)
            try:
                shutil.copy2(parsed['output'], cached)
                receipt.write_text(digest_file(cached))
            finally:
                root.unlock()
        log(dict(mode='exact-build', output=Path(parsed['output']).name, code=code,
                 seconds=round(time.monotonic() - started, 3)))
        return code
    finally:
        root.close()


def main(argv):
    prefix, args = split_prefix(argv)
    if os.environ.get('COS_TEST_KIT', '1') == '0':
        os.execvp(prefix[0], [*prefix, *args])
    parsed = parse(args)
    tc = toolchain(prefix[-1])
    match = match_kit(parsed) if parsed else None
    if match:
        return run_kit(prefix, parsed, match, tc)
    return run_exact(prefix, args, parsed, tc)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
