"""0.5.351: a per-mutant time limit for the mutation gates. A mutant that deadlocks (a checks binary stuck on a lock) hung a gate
for 3 hours. Every lane command here runs in its own process group with a limit; past it the whole group is killed and the
run is reported with returncode 124 and timed_out True, which the gates count as a kill by timeout (never a hang).

Only processes this module started are signalled, by their own process group.
"""
import os, signal, subprocess

class Result:
    def __init__(self, returncode, stdout, stderr, timed_out=False):
        self.returncode, self.stdout, self.stderr, self.timed_out = returncode, stdout, stderr, timed_out

def run(command, timeout, **kwargs):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True, **kwargs)
    try:
        out, err = process.communicate(timeout=timeout)
        return Result(process.returncode, out, err)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, err = process.communicate()
        return Result(124, out or "", (err or "") + f"\nmutate_bounded: killed after {timeout} s", timed_out=True)
