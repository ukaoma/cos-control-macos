#!/usr/bin/env python3
"""Serial Swift lane with the same BSD flock as compile-guard.sh.

No environment variable can relax this lane's resource ceilings. Receipts measure
owned descendant-tree RSS (not physical footprint); available memory includes
inactive pages, matching the ordinary guard. Sampling is a guard, not a hard OS
allocation limit. Never kills another application's processes.
"""
import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

GIB = 1024 ** 3
LOCK = '/tmp/cos-control-compile.lock'
START_FREE = 16 * GIB
RUN_FREE = 8 * GIB
RSS_CAP = 8 * GIB
SWAP_GROWTH = GIB
TIME_LIMIT = 3600
SAMPLE_SECONDS = .2


def normalize(command, environ):
    forbidden_env = ('COS_COMPILE_GUARD_HELD', 'COS_COMPILE_LOCK',
                     'COS_COMPILE_MIN_FREE_GB', 'COS_COMPILE_MAX_FRONTEND_GB',
                     'COS_COMPILE_MAX_TOTAL_GB', 'SWIFT_EXEC', 'SWIFT_DRIVER_SWIFT_FRONTEND_EXEC')
    if any(key in environ for key in forbidden_env):
        raise ValueError('inherited guard, lock or compiler/resource override is forbidden')
    if not command or Path(command[0]).name != 'swiftc':
        raise ValueError('bounded lane accepts a direct swiftc command only')
    executable = shutil.which(command[0])
    if not executable:
        raise ValueError('swiftc not found')
    # This is deliberately a small compiler option surface, not a shell runner.
    single = {'-typecheck', '-parse-as-library', '-g', '-Onone', '-O', '-Osize',
              '-warnings-as-errors', '-enable-testing', '-emit-executable', '-c', '-emit-module'}
    paired = {'-target', '-swift-version', '-strict-concurrency', '-sdk', '-module-name',
              '-module-cache-path', '-framework', '-weak-framework', '-I', '-F', '-L',
              '-l', '-D', '-o', '-Xlinker', '-Xcc', '-emit-module-path'}
    args = command[1:]
    i = 0
    sources = []
    while i < len(args):
        arg = args[i]
        if arg in paired:
            if i + 1 >= len(args) or args[i + 1].startswith('@'):
                raise ValueError('missing/indirect compiler option value')
            i += 2
            continue
        # Tests/kit-compile.py's harness link: an implicit @testable import of the shared kit, and nothing else.
        if arg == '-Xfrontend':
            if (args[i + 1:i + 3] != ['-testable-import-module', '-Xfrontend'] or i + 3 >= len(args)
                    or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', args[i + 3])):
                raise ValueError('unsupported bounded compiler argument: -Xfrontend')
            i += 4
            continue
        if arg in single or arg.startswith('-strict-concurrency='):
            i += 1
            continue
        if arg.endswith('.swift') and not arg.startswith(('-', '@')) and Path(arg).is_file():
            sources.append(arg)
            i += 1
            continue
        raise ValueError('unsupported bounded compiler argument: ' + arg)
    if not sources:
        raise ValueError('no Swift sources')
    return [executable, '-j', '1', '-disable-batch-mode', '-no-whole-module-optimization',
            '-num-threads', '1', *args]


def validate_plan(output):
    jobs = []
    module_jobs = 0
    for line in output.splitlines():
        if not line.strip():
            continue
        argv = shlex.split(line)
        if not argv:
            continue
        if Path(argv[0]).name == 'swift-frontend':
            if argv.count('-primary-file') != 1:
                # -emit-module adds ONE module job with no primary file (Tests/kit-compile.py's shared kit). Any other
                # frontend without exactly one primary is still refused.
                module_job = (argv.count('-primary-file') == 0 and '-c' not in argv
                              and ('-emit-module' in argv or '-merge-modules' in argv))
                if not module_job or module_jobs:
                    raise ValueError('frontend must have exactly one primary file')
                module_jobs += 1
            if '-whole-module-optimization' in argv:
                raise ValueError('whole-module frontend forbidden')
            if '-num-threads' in argv and argv[argv.index('-num-threads') + 1] != '1':
                raise ValueError('parallel frontend forbidden')
            jobs.append(argv)
        elif Path(argv[0]).name not in {'clang', 'ld', 'dsymutil', 'swift-autolink-extract'}:
            raise ValueError('unexpected driver job: ' + Path(argv[0]).name)
    if not jobs:
        raise ValueError('driver plan contains no verified frontend jobs')
    return len(jobs)


def telemetry(pgid=None):
    pages = subprocess.check_output(['/usr/bin/vm_stat'], text=True, timeout=5)
    size = re.search(r'page size of (\d+) bytes', pages)
    if not size:
        raise RuntimeError('cannot read page size')
    values = []
    for name in ('Pages free', 'Pages inactive', 'Pages speculative'):
        match = re.search(r'^' + name + r':\s+(\d+)\.', pages, re.M)
        if not match:
            raise RuntimeError('cannot read available memory')
        values.append(int(match[1]))
    swap = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'vm.swapusage'], text=True, timeout=5)
    used = re.search(r'used\s*=\s*([\d.]+)([KMG])', swap)
    if not used:
        raise RuntimeError('cannot read swap usage')
    rss = 0
    if pgid is not None:
        processes = subprocess.check_output(['/bin/ps', '-axo', 'pgid=,rss='], text=True, timeout=5)
        for line in processes.splitlines():
            group, kb = line.split()
            if int(group) == pgid:
                rss += int(kb) * 1024
    return {'availableBytes': sum(values) * int(size[1]),
            'swapBytes': int(float(used[1]) * {'K': 1024, 'M': 1024**2, 'G': GIB}[used[2]]),
            'rssBytes': rss}


class BSDInfo(ctypes.Structure):
    # SDK sys/proc_info.h struct proc_bsdinfo; microsecond birth identity avoids
    # signalling an unrelated process that reused a retained PID.
    _fields_ = [(name, ctypes.c_uint32) for name in ('flags', 'status', 'xstatus', 'pid', 'ppid',
               'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]


LIBPROC = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
LIBPROC.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
LIBPROC.proc_pidinfo.restype = ctypes.c_int


class ProcessIdentityUnavailable(RuntimeError):
    pass


def process_info(pid):
    info = BSDInfo()
    ctypes.set_errno(0)
    size = LIBPROC.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size == ctypes.sizeof(info):
        return info
    failure = ctypes.get_errno()
    if failure == errno.ESRCH:
        return None  # Kernel explicitly confirms this PID no longer exists.
    raise ProcessIdentityUnavailable('process birth telemetry unavailable for PID ' + str(pid))


def birth(info):
    return (info.seconds, info.microseconds)


class ProcessTree:
    def __init__(self, pid):
        info = process_info(pid)
        if info is None:
            raise RuntimeError('cannot establish compiler birth identity')
        self.owned = {pid: birth(info)}
        self.seen_frontends = set()
        self.peak = 0
        self.max_processes = 0
        self.max_groups = 0

    def sample(self):
        output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,rss=,comm='], text=True, timeout=5)
        rows = {}
        for line in output.splitlines():
            parts = line.split(None, 4)
            if len(parts) == 5:
                rows[int(parts[0])] = (int(parts[1]), int(parts[2]), int(parts[3])*1024, parts[4])
        alive = {}
        for pid, identity in self.owned.items():
            info = process_info(pid)
            if pid in rows and info is not None and birth(info) == identity and info.status != 5:
                alive[pid] = info
        changed = True
        while changed:
            changed = False
            for pid, row in rows.items():
                if pid not in alive and row[0] in alive:
                    info = process_info(pid)
                    if info is not None and info.ppid == row[0] and info.uid == os.getuid() and info.status != 5:
                        # Retain ownership even after reparenting or setsid().
                        self.owned[pid] = birth(info)
                        alive[pid] = info
                        changed = True
        rss = sum(rows[pid][2] for pid in alive)
        for pid, info in alive.items():
            if Path(rows[pid][3]).name == 'swift-frontend':
                self.seen_frontends.add((pid, *birth(info)))
        self.peak = max(self.peak, rss)
        self.max_processes = max(self.max_processes, len(alive))
        self.max_groups = max(self.max_groups, len({info.pgid for info in alive.values()}))
        return {'rssBytes': rss, 'peakOwnedRSSBytes': self.peak,
                'observedFrontendProcesses': len(self.seen_frontends),
                'maxOwnedProcesses': self.max_processes, 'maxOwnedProcessGroups': self.max_groups}

    def signal_owned(self, sig):
        for pid, identity in list(self.owned.items()):
            try:
                info = process_info(pid)
            except ProcessIdentityUnavailable:
                continue  # Cannot safely signal; cleanup retains the lock and retries.
            if info is not None and birth(info) == identity and info.status != 5:
                try:
                    os.kill(pid, sig)
                except OSError:
                    pass  # A failed signal is not proof of exit. running() checks again.

    def cleanup(self, process):
        # Enumeration is best effort DURING cleanup. It must never prevent
        # signalling the birth-verified descendants already discovered.
        def refresh():
            try:
                self.sample()
            except Exception:
                pass
        refresh()
        self.signal_owned(signal.SIGTERM)
        deadline = time.monotonic() + .5
        while time.monotonic() < deadline:
            process.poll()
            refresh()
            if not self.running():
                process.wait()
                return
            time.sleep(.02)
        # Unknown identity is still potentially alive. Keep the inherited lock
        # indefinitely if necessary; only confirmed disappearance, zombie state,
        # or a different birth identity can release ownership of a retained PID.
        while self.running():
            refresh()
            self.signal_owned(signal.SIGKILL)
            process.poll()
            time.sleep(.05)
        process.wait()

    def running(self):
        for pid, identity in self.owned.items():
            try:
                info = process_info(pid)
            except ProcessIdentityUnavailable:
                return True
            if info is not None and birth(info) == identity and info.status != 5:
                return True
        return False


class OwnedProcess:
    """Guardian retains flock and observes a private parent-liveness pipe.

    It starts BEFORE the compiler, avoiding a launch-to-guardian orphan gap.
    Compiler and guardian inherit the locked descriptor; parent SIGKILL closes
    the liveness pipe and the guardian terminates the compiler process group.
    """
    def __init__(self, command, lock_fd=None, stdout=None, stderr=None):
        life_read, life_write = os.pipe()
        result_read, result_write = os.pipe()
        self.guardian_pid = os.fork()
        if self.guardian_pid == 0:
            os.close(life_write)
            os.close(result_read)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            process = None
            tree = None
            try:
                process = subprocess.Popen(command, start_new_session=True, stdout=stdout, stderr=stderr,
                                           pass_fds=(() if lock_fd is None else (lock_fd,)))
                tree = ProcessTree(process.pid)
                os.write(result_write, (json.dumps({'pid': process.pid}) + '\n').encode())
                while process.poll() is None:
                    metrics = tree.sample()
                    os.write(result_write, (json.dumps({'metrics': metrics}) + '\n').encode())
                    if metrics['rssBytes'] > RSS_CAP:
                        tree.cleanup(process)
                        break
                    if select.select([life_read], [], [], .05)[0]:
                        # Stop request OR EOF from a dead wrapper. Neither can
                        # release the inherited lock before compiler cleanup.
                        os.read(life_read, 1)
                        tree.cleanup(process)
                        break
                code = process.wait()
                tree.cleanup(process)
                os.write(result_write, (json.dumps({'exit': code, 'metrics': tree.sample()}) + '\n').encode())
            except BaseException as error:
                if tree is not None:
                    tree.cleanup(process)
                elif process is not None:
                    stop_group(process)
                try:
                    os.write(result_write, (json.dumps({'error': str(error)}) + '\n').encode())
                except BrokenPipeError:
                    pass
            finally:
                if tree is not None:
                    tree.cleanup(process)
                os.close(life_read)
                os.close(result_write)
                if lock_fd is not None:
                    os.close(lock_fd)
                os._exit(0)
        os.close(life_read)
        os.close(result_write)
        self.life_write = life_write
        self.result_read = result_read
        self.returncode = None
        self.buffer = b''
        self.closed = False
        self.metrics = {'rssBytes': 0}
        try:
            message = self.read_message(block=True)
            if 'pid' not in message:
                raise RuntimeError(message.get('error', 'guardian did not launch compiler'))
            self.pid = message['pid']
        except BaseException:
            os.close(self.life_write)  # EOF tells guardian to clean up even during startup.
            os.close(self.result_read)
            os.waitpid(self.guardian_pid, 0)
            raise

    def read_message(self, block=False):
        while b'\n' not in self.buffer:
            if not block and not select.select([self.result_read], [], [], 0)[0]:
                return None
            chunk = os.read(self.result_read, 4096)
            if not chunk:
                raise RuntimeError('guardian ended without compiler result')
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line)

    def poll(self):
        if self.returncode is not None:
            return self.returncode
        while True:
            message = self.read_message()
            if message is None:
                break
            if 'error' in message:
                self.returncode = 70
                self.wait()
                raise RuntimeError(message['error'])
            if 'metrics' in message:
                self.metrics = message['metrics']
            if 'exit' in message:
                self.returncode = message['exit']
                break
        return self.returncode

    def wait(self):
        while self.poll() is None:
            time.sleep(.01)
        if not self.closed:
            os.waitpid(self.guardian_pid, 0)
            os.close(self.life_write)
            os.close(self.result_read)
            self.closed = True
        return self.returncode

    def stop(self):
        if not self.closed:
            try:
                os.write(self.life_write, b'S')
            except BrokenPipeError:
                pass
            self.wait()


def stop_group(process):
    if isinstance(process, OwnedProcess):
        process.stop()
        return
    # Kill descendants even if the driver itself has already exited.
    for sig, wait in ((signal.SIGTERM, .5), (signal.SIGKILL, 0)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        if wait:
            time.sleep(wait)
            process.poll()  # Reap an exited group leader before signalling descendants on macOS.
    process.wait()


def run_owned(command, measure=telemetry, interval=SAMPLE_SECONDS, timeout=TIME_LIMIT, stdout=None, stderr=None, lock_fd=None):
    started = time.monotonic()
    first = measure(None)
    report = {'startAvailableBytes': first['availableBytes'], 'startSwapBytes': first['swapBytes'],
              'peakOwnedRSSBytes': 0, 'minAvailableBytes': first['availableBytes'],
              'maxSwapGrowthBytes': 0}
    if first['availableBytes'] < START_FREE:
        return {**report, 'status': 'refused', 'reason': 'startup headroom below 16 GiB', 'exitCode': 75, 'elapsedSeconds': 0}
    process = OwnedProcess(command, lock_fd=lock_fd, stdout=stdout, stderr=stderr)
    reason = None
    try:
        while process.poll() is None:
            sample = measure(process.pid)
            sample['rssBytes'] = max(sample['rssBytes'], process.metrics['rssBytes'])
            report['peakOwnedRSSBytes'] = max(report['peakOwnedRSSBytes'], sample['rssBytes'])
            report['minAvailableBytes'] = min(report['minAvailableBytes'], sample['availableBytes'])
            growth = max(0, sample['swapBytes'] - first['swapBytes'])
            report['maxSwapGrowthBytes'] = max(report['maxSwapGrowthBytes'], growth)
            if sample['rssBytes'] > RSS_CAP:
                reason = 'owned descendant tree exceeded 8 GiB RSS'
            elif sample['availableBytes'] < RUN_FREE:
                reason = 'running headroom below 8 GiB'
            elif growth > SWAP_GROWTH:
                reason = 'system swap grew more than 1 GiB'
            elif time.monotonic() - started > timeout:
                reason = 'bounded command exceeded time limit'
            if reason:
                break
            time.sleep(interval)
        if reason:
            stop_group(process)
            code = 137
        else:
            code = process.wait()
            # Never leave owned children behind after a failed/finished driver.
            stop_group(process)
    except BaseException:
        stop_group(process)
        raise
    report['peakOwnedRSSBytes'] = max(report['peakOwnedRSSBytes'], process.metrics.get('peakOwnedRSSBytes', 0))
    for key in ('observedFrontendProcesses', 'maxOwnedProcesses', 'maxOwnedProcessGroups'):
        report[key] = process.metrics.get(key, 0)
    if report['peakOwnedRSSBytes'] > RSS_CAP:
        reason = 'owned descendant tree exceeded 8 GiB RSS'
        code = 137
    return {**report, 'status': 'stopped' if reason else ('passed' if code == 0 else 'failed'),
            'reason': reason, 'exitCode': code, 'elapsedSeconds': round(time.monotonic() - started, 3)}


def write_receipt(path, report):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix='.bounded-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(report, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--receipt', required=True, type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    report = {'schema': 1, 'profile': 'bounded', 'pid': os.getpid(),
              'policy': {'startupAvailableBytes': START_FREE, 'runningAvailableBytes': RUN_FREE,
                         'ownedRSSCapBytes': RSS_CAP, 'swapGrowthCapBytes': SWAP_GROWTH,
                         'sampleSeconds': SAMPLE_SECONDS, 'timeoutSeconds': TIME_LIMIT},
              'startedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    code = 70
    def interrupted(signum, frame):
        raise InterruptedError('wrapper interrupted by signal ' + str(signum))
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    lock = None
    try:
        normalized = normalize(command, os.environ)
        report['commandSHA256'] = hashlib.sha256('\0'.join(normalized).encode()).hexdigest()
        lock = os.open(LOCK, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        deadline = time.monotonic() + 120
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('shared compile lock busy after 120 seconds')
                time.sleep(.2)
        # Driver-only planning runs under the same watchdog and lock; it cannot compile.
        with tempfile.TemporaryFile(mode='w+') as plan_out, tempfile.TemporaryFile(mode='w+') as plan_err:
            planning = run_owned([normalized[0], '-driver-print-jobs', *normalized[1:]],
                                 timeout=30, stdout=plan_out, stderr=plan_err, lock_fd=lock)
            report['planning'] = planning
            if planning['exitCode'] != 0:
                report.update(planning)
                return planning['exitCode']
            plan_out.seek(0)
            plan_err.seek(0)
            plan = plan_out.read() + plan_err.read()
        report['frontendJobs'] = validate_plan(plan)
        report['planSHA256'] = hashlib.sha256(plan.encode()).hexdigest()
        report.update(run_owned(normalized, lock_fd=lock))
        code = report['exitCode']
    except BaseException as error:
        report.update(status='infrastructure-error', reason=str(error), exitCode=70)
        print('compile-bounded: ' + str(error), file=sys.stderr)
    finally:
        if lock is not None:
            os.close(lock)
        write_receipt(args.receipt, report)
        print('compile-bounded: ' + report['status'] + '; receipt ' + str(args.receipt), file=sys.stderr)
    return code


if __name__ == '__main__':
    sys.exit(main())
