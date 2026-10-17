#!/usr/bin/env python3
"""Mutation gate for COS_COMPILE_SLOTS (compile-bounded.py, compile-guard.sh), executed by Tests/test-compile-slots.py.

Stand-in compilers only, no Swift, never the machine's real compile lock. Works on a scratch copy of Tests/. Requires a
GREEN baseline; every mutant must land exactly once and make the slot tests FAIL.

Usage: python3 Tests/mutate-compile-slots.py [mutant name ...]
"""
import pathlib, shutil, subprocess, sys, tempfile
src = pathlib.Path(__file__).resolve().parent
B, G = 'compile-bounded.py', 'compile-guard.sh'
M = [
 ("slotted takes LOCK exclusive (no sharing)", B, "fcntl.flock(base, fcntl.LOCK_SH | fcntl.LOCK_NB)", "fcntl.flock(base, fcntl.LOCK_EX | fcntl.LOCK_NB)"),
 ("slotted skips the gate", B, "                fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)\n                try:", "                pass\n                try:"),
 ("large path without the gate", G, '/usr/bin/lockf -k -t 1800 "$LOCK.gate" /usr/bin/lockf', '/usr/bin/lockf'),
 ("switch stops any compile, not the newest", B, "        if not live or max(live, key=lambda o: (o['acquiredNs'], o['pid']))['pid'] != me:", "        if not live:"),
 ("switch stops a lone compile", B, "        if total <= cap or total - mine <= 0:", "        if total <= cap:"),
 ("switch ignores the cap", B, "        if total <= cap or total - mine <= 0:", "        if total - mine <= 0:"),
 ("switch never consulted", B, "            elif switch is not None:\n                reason = switch(process)\n", ""),
 ("no owner registered", B, "            register_owner(slot)\n", ""),
 ("owner never released", B, "        if slot is not None:\n            release_owner(slot)\n", ""),
 ("slots>1 not routed to bounded", G, "{ (( SLOTS > 1 )) || (( $(free_gb) < MIN_FREE_GB )); }", "(( $(free_gb) < MIN_FREE_GB ))"),
 ("guard accepts any slot count", G, """[[ "$SLOTS" =~ '^[1-8]$' ]] ||""", "true ||"),
 ("bounded accepts any slot count", B, "if not re.fullmatch(r'[1-8]', raw):", "if not re.fullmatch(r'[0-9]+', raw):"),
 ("total cap allowed with one slot", B, "    if slot_count(environ) > 1:\n        # Slotted only", "    if True:\n        # Slotted only"),
 ("total cap never allowed", B, "        forbidden_env = tuple(key for key in forbidden_env if key != 'COS_COMPILE_MAX_TOTAL_GB')", "        pass"),
 ("one slot takes the slotted path", B, "    if slots == 1:\n        deadline", "    if False:\n        deadline"),
 ("a third compile shares a slot", B, "                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)", "                        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)"),
 ("non-positive total cap accepted", B, "    if not re.fullmatch(r'\\d+(\\.\\d+)?', raw) or float(raw) <= 0:", "    if not re.fullmatch(r'\\d+(\\.\\d+)?', raw):"),
]
work = pathlib.Path(tempfile.mkdtemp(prefix='cos-slot-mutants-', dir='/tmp'))
try:
    shutil.copytree(src, work / 'Tests', ignore=shutil.ignore_patterns('fixtures', '__pycache__'))
    T = work / 'Tests'
    def run():
        return subprocess.run([sys.executable, str(T / 'test-compile-slots.py')], capture_output=True, text=True, timeout=600)
    base = run()
    if base.returncode: sys.exit('baseline red:\n' + base.stderr[-2000:])
    print('baseline GREEN', flush=True)
    survivors = []
    only = sys.argv[1:]
    for name, f, old, new in [m for m in M if not only or m[0] in only]:
        text = (T / f).read_text()
        assert text.count(old) == 1, (name, text.count(old))
        (T / f).write_text(text.replace(old, new))
        r = run()
        (T / f).write_text(text)
        fails = [l.split('(')[0].replace('FAIL: ', '').replace('ERROR: ', '') for l in r.stderr.splitlines() if l.startswith(('FAIL:', 'ERROR:'))]
        verdict = 'KILLED' if r.returncode else 'SURVIVED'
        if not r.returncode: survivors.append(name)
        print(f'{verdict:9} {name} :: {", ".join(fails)}', flush=True)
    if survivors:
        sys.exit(f'{len(survivors)} survivor(s): {survivors}')
    print(f'PASS compile slots mutation gate: every mutant killed, green baseline')
finally:
    shutil.rmtree(work, ignore_errors=True)
