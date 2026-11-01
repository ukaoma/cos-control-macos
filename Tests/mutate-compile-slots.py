#!/usr/bin/env python3
"""Mutation gate for COS_COMPILE_SLOTS and the compile guard (compile-bounded.py, compile-guard.sh, scripts/build-release.sh),
executed by Tests/test-compile-slots.py (SlotTests, and WatchdogTests for the large-profile stop) and Tests/test-compile-bounded.py
(the --jobs tests).

Stand-in compilers only, no Swift, never the machine's real compile lock. Works on a scratch copy of Tests/ and
scripts/build-release.sh. Requires a GREEN baseline of both test files; every mutant must land exactly once and make its tests
FAIL. The slot tests run with -f (stop at the first failure), so a killed mutant names the first test that caught it.
The tree-kill pattern mutant only ever pkills stand-ins under the test's own temp directory (COS_TEST_FRONTEND_DIR, and the
`:?` makes it a shell error if unset): a mutant must never be able to stop another session's real compile.

Usage: python3 Tests/mutate-compile-slots.py [mutant name ...]
"""
import os, pathlib, shutil, subprocess, sys, tempfile
src =pathlib.Path(__file__).resolve().parent
B, G, R = 'compile-bounded.py', 'compile-guard.sh', '../scripts/build-release.sh'
SLOTS = ('test-compile-slots.py', '-f', 'SlotTests')
WATCH = ('test-compile-slots.py', '-f', 'WatchdogTests')
BLOCKER_ENV = {'COS_COMPILE_PROFILE': 'bounded', 'COS_TEST_KIT_PERSIST': '1'}  # what run.sh exports
HOSTILE_ENV = {'COS_COMPILE_PROFILE': 'large', 'COS_TEST_KIT_PERSIST': '1', 'COS_COMPILE_SLOTS': '3', 'COS_COMPILE_GUARD_HELD': '1',
               'COS_COMPILE_LOCK': '/tmp/cos-hostile-lock', 'COS_COMPILE_MIN_FREE_GB': '0', 'COS_COMPILE_MAX_TOTAL_GB': '1',
               'COS_COMPILE_MAX_FRONTEND_GB': '1', 'SWIFT_EXEC': '/nonexistent'}  # every variable that steers the guard, all wrong
JOBS = ('test-compile-bounded.py', '-k', 'jobs')
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
 ("one slot takes the slotted path", B, "    if slots == 1:\n        # 2026-10-31 (build-speed A6)", "    if False:\n        # 2026-10-31 (build-speed A6)"),
 ("a third compile shares a slot", B, "                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)", "                        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)"),
 ("non-positive total cap accepted", B, "    if not re.fullmatch(r'\\d+(\\.\\d+)?', raw) or float(raw) <= 0:", "    if not re.fullmatch(r'\\d+(\\.\\d+)?', raw):"),
 # A6 (2026-10-31): SLOTS=1 takes the gate, waits SLOT_WAIT, says so about every minute.
 ("one slot gives up after 120 s again", B, "        limit = SLOT_WAIT if wait is None else wait\n", "        limit = 120 if wait is None else wait\n"),
 ("one slot skips the gate", B, "                        fcntl.flock(gate, fcntl.LOCK_EX | fcntl.LOCK_NB)\n                        have_gate = True\n", "                        have_gate = True\n"),
 ("one slot lets go of the gate between polls", B, "                except BlockingIOError:\n                    pass\n                now = time.monotonic()\n",
  "                except BlockingIOError:\n                    fcntl.flock(gate, fcntl.LOCK_UN)\n                    have_gate = False\n                now = time.monotonic()\n"),
 ("one slot keeps the gate for the whole compile", B, "                    fcntl.flock(gate, fcntl.LOCK_UN)\n                    os.close(gate)\n                    return [base], None\n", "                    return [base, gate], None\n"),
 ("one slot never says it is waiting", B, "                if now - last >= PROGRESS_SECONDS:\n", "                if False:\n"),
 ("one slot says it on every poll", B, "                if now - last >= PROGRESS_SECONDS:\n", "                if True:\n"),
 ("one slot timeout message says 120", B, "raise TimeoutError(f'shared compile lock busy after {int(limit)} seconds')", "raise TimeoutError('shared compile lock busy after 120 seconds')"),
 ("one slot timeout leaves the gate held", B, "            for fd in (base, gate):\n", "            for fd in (base,):\n"),
 # A5 (2026-10-31): the release pins bounded; the guard's bounded pin outranks free memory; the stop kills only its own tree.
 ("release build sets no profile", R, "export COS_COMPILE_PROFILE=bounded\n", ""),
 ("release build sets the profile but does not export it", R, "export COS_COMPILE_PROFILE=bounded\n", "COS_COMPILE_PROFILE=bounded\n"),
 ("bounded pin does not outrank free memory", G, '{ [[ "$PROFILE" == bounded ]] || { [[ "$PROFILE" == auto', '{ false || { [[ "$PROFILE" == auto'),
 # Review 1 (2026-10-31): the watchdog's owned set, orphans, foreign offenders, freeze-then-kill; the release's kit-store pin; no --jobs in the guard.
 ("guard tests inherit run.sh's profile (scrub off AND no explicit profile)", 'test-compile-slots.py',
  ("    env = {k: v for k, v in os.environ.items() if not k.startswith(('COS_COMPILE', 'COS_TEST_KIT', 'SWIFT_'))}\n", "COS_COMPILE_PROFILE='auto', COS_COMPILE_MIN_FREE_GB='0', FAKE_RAN=str(ran),\n"),
  ("    env = dict(os.environ)\n", "COS_COMPILE_MIN_FREE_GB='0', FAKE_RAN=str(ran),\n"), SLOTS, BLOCKER_ENV),
 ("guard tests inherit every steering variable", 'test-compile-slots.py',
  "    env = {k: v for k, v in os.environ.items() if not k.startswith(('COS_COMPILE', 'COS_TEST_KIT', 'SWIFT_'))}\n", "    env = dict(os.environ)\n", SLOTS, HOSTILE_ENV),
 ("guard passes --jobs to the bounded lane", G, '--receipt "$RECEIPT" -- "$@"', '--receipt "$RECEIPT" --jobs 4 -- "$@"'),
 ("release build lets an inherited kit store through", R, "export COS_TEST_KIT_PERSIST=0\n", ""),
 ("release build sets the kit store switch but does not export it", R, "export COS_TEST_KIT_PERSIST=0\n", "COS_TEST_KIT_PERSIST=0\n"),
 ("release build asks for a persistent kit store", R, "export COS_TEST_KIT_PERSIST=0\n", "export COS_TEST_KIT_PERSIST=1\n"),
 ("stop pattern-kills swift-frontends outside the tree", G, '  kill -9 "${pids[@]}" $CMD 2>/dev/null\n',
  '  pkill -9 -f "${COS_TEST_FRONTEND_DIR:?}/swift-frontend"; kill -9 "${pids[@]}" $CMD 2>/dev/null\n', WATCH),
 ("stop kills the command only", G, '  kill -9 "${pids[@]}" $CMD 2>/dev/null\n', '  kill -9 $CMD 2>/dev/null\n', WATCH),
 ("owned set follows only the command's direct children", G, "for (p in alive) if (!(p in own) && (ppid[p] in own))", "for (p in alive) if (!(p in own) && (ppid[p] == root))", WATCH),
 ("owned set is not carried across samples", G, '-v prev="$OWNED"', '-v prev=""', WATCH),
 ("owned set ignores a changed start time (reused pid)", G, "if ((kv[1] in alive) && st[kv[1]] == kv[2])", "if (kv[1] in alive)", WATCH),
 ("trip counts foreign frontends", G, 'if (rss[p] > max) forbig = forbig " " p ":" rss[p] }', 'if (rss[p] > max) { forbig = forbig " " p ":" rss[p]; ownbig = ownbig " " p } }', WATCH),
 ("foreign frontend is not named", G, '    echo "compile-guard: NOTE: swift-frontend pid $pid holds', '    : "compile-guard: NOTE: swift-frontend pid $pid holds', WATCH),
 ("foreign frontend is named on every sample", G, '    [[ -n "${WARNED[$pid]:-}" ]] && continue\n', "", WATCH),
 ("machine total over the cap does not stop this run", G, "    elif (( ALL_FE_KB > MAX_TOTAL_GB * 1048576 )); then\n", "    elif (( 0 )); then\n", WATCH),
 ("machine total stop names no offenders", G, 'Not stopped, not touched: $(foreign_top)"', 'Not stopped, not touched: nobody"', WATCH),
 ("own total over the cap is worded as the machine's", G, "    if (( OWN_FE_KB > MAX_TOTAL_GB * 1048576 )); then\n", "    if (( 0 )); then\n", WATCH),
 ("stop kills without freezing the tree first", G, '    kill -STOP "${pids[@]}" 2>/dev/null\n', "", WATCH),
 ("stop scans the tree only once", G, "  for i in {1..20}; do\n", "  for i in {1..1}; do\n", WATCH),
 # B4 (2026-10-31): --jobs, trial only.
 ("jobs argument ignored", B, "    return [executable, '-j', str(jobs), ", "    return [executable, '-j', '1', ", JOBS),
 ("jobs 0 accepted", B, "or not 1 <= jobs <= MAX_JOBS", "or not 0 <= jobs <= MAX_JOBS", JOBS),
 ("jobs 9 accepted", B, "or not 1 <= jobs <= MAX_JOBS", "or not 1 <= jobs <= MAX_JOBS + 1", JOBS),
 ("jobs True accepted", B, "isinstance(jobs, bool) or ", "", JOBS),
 ("jobs not recorded in the receipt", B, "'profile': 'bounded', 'jobs': args.jobs, ", "'profile': 'bounded', ", JOBS),
 ("jobs argument not passed on", B, "normalize(command, os.environ, args.jobs)", "normalize(command, os.environ)", JOBS),
 ("jobs default is 4", B, "parser.add_argument('--jobs', type=int, default=1)", "parser.add_argument('--jobs', type=int, default=4)", JOBS),
 ("raw -j accepted on the swiftc line", B, "    paired = {'-target', '-swift-version',", "    paired = {'-j', '-target', '-swift-version',", JOBS),
 ("jobs read from the environment", B, "def normalize(command, environ, jobs=1):\n", "def normalize(command, environ, jobs=1):\n    jobs = int(environ.get('COS_COMPILE_JOBS', jobs))\n", JOBS),
]
work = pathlib.Path(tempfile.mkdtemp(prefix='cos-slot-mutants-', dir='/tmp'))
try:
    shutil.copytree(src, work / 'Tests', ignore=shutil.ignore_patterns('fixtures', '__pycache__'))
    (work / 'scripts').mkdir()
    shutil.copy2(src.parent / 'scripts' / 'build-release.sh', work / 'scripts' / 'build-release.sh')
    T = work / 'Tests'
    def run(tests, extra_env=None):
        env = {**os.environ, **(extra_env or {})}
        return subprocess.run([sys.executable, str(T / tests[0]), *tests[1:]], capture_output=True, text=True, timeout=600, env=env)
    # The whole of both files, unmutated, before the first mutant: once in the runner's own environment, once with what run.sh exports.
    for baseline, extra in (('test-compile-slots.py', None), ('test-compile-bounded.py', None), ('test-compile-slots.py', BLOCKER_ENV), ('test-compile-bounded.py', BLOCKER_ENV),
                            ('test-compile-slots.py', HOSTILE_ENV), ('test-compile-bounded.py', HOSTILE_ENV)):
        base = run((baseline,), extra)
        if base.returncode: sys.exit(f'baseline red ({baseline}, env {extra}):\n' + base.stderr[-2000:])
    print('baseline GREEN (test-compile-slots.py, test-compile-bounded.py; also with the exports run.sh makes, and with every steering variable set wrong)', flush=True)
    survivors, hung = [], []
    only = sys.argv[1:]
    chosen = [m for m in M if not only or m[0] in only]
    if only and len(chosen) != len(set(only)): sys.exit(f'unknown or duplicate mutant name in {only}')
    for name, f, old, new, *rest in chosen:
        text = (T / f).read_text()
        mutated = text
        for o, n in (zip(old, new) if isinstance(old, tuple) else [(old, new)]):  # one pair, or several that must all land
            assert mutated.count(o) == 1, (name, mutated.count(o))  # the target is there exactly once
            assert o != n, name
            before, mutated = mutated, mutated.replace(o, n)
            assert mutated != before and mutated.count(o) == (1 if o in n else 0), name  # and the replacement actually landed
        (T / f).write_text(mutated)
        try:
            r = run(rest[0] if rest and rest[0] else SLOTS, rest[1] if len(rest) > 1 else None)
        except subprocess.TimeoutExpired:
            # A mutant that hangs the tests is caught, but by the clock and not by a check that names it, so it is listed apart.
            hung.append(name)
            print(f'HUNG      {name} :: no result in 600 s', flush=True)
            continue
        finally:
            (T / f).write_text(text)
        fails = [l.split('(')[0].replace('FAIL: ', '').replace('ERROR: ', '') for l in r.stderr.splitlines() if l.startswith(('FAIL:', 'ERROR:'))]
        verdict = 'KILLED' if r.returncode else 'SURVIVED'
        if not r.returncode: survivors.append(name)
        print(f'{verdict:9} {name} :: {", ".join(fails)}', flush=True)
    killed = len(chosen) - len(survivors) - len(hung)
    if hung: print(f'{len(hung)} mutant(s) hung: {hung}')
    if survivors:
        sys.exit(f'{killed} killed, {len(survivors)} survivor(s): {survivors}')
    print(f'PASS compile slots mutation gate: {killed} of {len(chosen)} mutants killed, {len(hung)} hung, green baseline')
finally:
    shutil.rmtree(work, ignore_errors=True)
