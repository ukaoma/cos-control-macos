#!/usr/bin/env python3
"""0.5.312 `work-session-meter`: bounded transcript tail, numbers and paths only, read-only git. Isolated /tmp home."""
import datetime, json, os, pathlib, shutil, subprocess, sys, tempfile, uuid

helper = str(pathlib.Path(sys.argv[1]).resolve())
root = pathlib.Path(tempfile.mkdtemp(prefix='cos-work-meter-', dir='/tmp'))
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(root))
SECRET = 'PRIVATE-TRANSCRIPT-TEXT'
checks = 0


def check(ok, why):
    global checks
    assert ok, why
    checks += 1


def run(*args):
    proc = subprocess.run([helper, 'work-session-meter', *args], capture_output=True, env=env, timeout=30)
    check(SECRET.encode() not in proc.stdout and SECRET.encode() not in proc.stderr, 'transcript text never leaves the helper')
    return json.loads(proc.stdout)


def iso(text):
    return datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()


try:
    since = iso('2026-10-15T11:00:00Z')
    # A git repo with one commit before the handoff, one after, and uncommitted work.
    repo = root / 'repo'; repo.mkdir()
    gitenv = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@e', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@e')
    def git(*a, date=None):
        e = dict(gitenv, **({'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date} if date else {}))
        return subprocess.run(['git', '-C', str(repo), *a], env=e, capture_output=True, text=True, check=True).stdout
    git('init', '-q')
    (repo / 'a.txt').write_text('1\n2\n3\n4\n5\n'); git('add', '-A'); git('commit', '-qm', 'before', date='2026-10-15T10:00:00Z')
    (repo / 'a.txt').write_text('one\n2\n3\n4\n5\n6\n7\n'); (repo / 'b.txt').write_text('x\ny\nz\n'); git('add', '-A'); git('commit', '-qm', 'after', date='2026-10-15T12:00:00Z')
    (repo / 'a.txt').write_text('one\n2\n3\n4\n5\n6\n7\n8\n9\n')
    base = git('rev-list', '-1', '--before=2026-10-15T11:00:00Z', 'HEAD').strip()
    expected = git('diff', '--shortstat', base).strip()

    # Claude: an output written early (beyond the tail window), > 4 MB of padding, then the newest turns.
    sid = str(uuid.uuid4())
    project = root / '.claude/projects/-tmp-proj'; project.mkdir(parents=True)
    head_file = repo / 'HEAD_OUTPUT.md'; head_file.write_text('x')
    tail_file = repo / 'TAIL_OUTPUT.md'; tail_file.write_text('x')
    image = repo / 'shot.png'; image.write_bytes(b'\x89PNG')
    def assistant(ts, usage, tools):
        return {'type': 'assistant', 'timestamp': ts, 'cwd': str(repo), 'message': {'role': 'assistant', 'model': 'claude-opus-5-5', 'usage': usage,
                'content': [{'type': 'text', 'text': SECRET}] + [{'type': 'tool_use', 'id': 't', 'name': n, 'input': {'file_path': p}} for n, p in tools]}}
    rows = [assistant('2026-10-15T11:30:00.000Z', {'input_tokens': 1, 'cache_read_input_tokens': 1}, [('Write', str(head_file))])]
    pad = {'type': 'user', 'timestamp': '2026-10-15T11:31:00.000Z', 'cwd': str(repo), 'message': {'role': 'user', 'content': SECRET + 'p' * 20_000}}
    rows += [pad] * 260  # about 5 MB: the head is past the 4 MB outputs window
    rows.append(assistant('2026-10-15T12:20:00.000Z', {'input_tokens': 4, 'cache_read_input_tokens': 160_000, 'cache_creation_input_tokens': 6_000},
                          [('Edit', str(image)), ('Write', str(repo / 'deleted-since.md'))]))
    rows.append(assistant('2026-10-15T12:30:00.000Z', {'input_tokens': 10, 'cache_read_input_tokens': 170_000, 'cache_creation_input_tokens': 1_000},
                          [('Write', str(tail_file))]))
    transcript = project / f'{sid}.jsonl'
    transcript.write_text('\n'.join(json.dumps(r) for r in rows) + '\n')
    check(transcript.stat().st_size > 4_500_000, 'the fixture is bigger than the bounded windows')

    # Snapshot AFTER every fixture file is written (several are output files inside the repo), right before the helper runs.
    status_before = git('status', '--porcelain'); index = repo / '.git/index'; index_before = index.stat().st_mtime_ns
    result = run('--session', f'claude:{sid}', '--since', f'{since:.3f}')
    d = result['details']
    check(result['ok'] and d['known'] is True and d['provider'] == 'claude', 'a Claude transcript is known')
    check(d['context'] == {'used': 171_010, 'window': 1_000_000, 'model': 'claude-opus-5-5'}, 'context from the newest usage line; Opus 5.5 is a 1M window')
    check([o['path'] for o in d['outputs']] == [str(tail_file), str(image)], 'existing outputs since the handoff, newest first; a deleted file is not listed')
    check(d['outputsTotal'] == 2 and d['outputsPartial'] is True, 'an output older than the bounded window is not read, and that is said')
    check(str(head_file) not in json.dumps(d), 'the head of a multi-MB transcript is never read')
    check(d['cwd'] == str(repo), 'working folder from the transcript')
    if 'gitUnavailable' in d['changes']:
        print('note: no developer git on this Mac; changes reported as unavailable')
    else:
        c = d['changes']
        check(c['repo'] is True and c['baseFound'] is True, 'a repo with a commit before the handoff')
        check(f" {c['files']} files changed, {c['insertions']} insertions(+), {c['deletions']} deletion" in ' ' + expected, f'shortstat matches git: {expected}')
        check((c['files'], c['insertions'], c['deletions']) == (2, 8, 1) and {f['path'] for f in c['perFile']} == {'a.txt', 'b.txt'},
              'commits since the handoff plus uncommitted work, per file')
        check(index.stat().st_mtime_ns == index_before and git('status', '--porcelain') == status_before, 'git never wrote to the repo')

    # No --since: context only.
    d = run('--session', f'claude:{sid}')['details']
    check('context' in d and 'outputs' not in d and 'changes' not in d, 'no handoff time: no outputs or changes')

    # Not a repo: no changes.
    plain = root / 'plain'; plain.mkdir()
    sid2 = str(uuid.uuid4())
    (project / f'{sid2}.jsonl').write_text(json.dumps(assistant('2026-10-15T12:00:00.000Z', {'input_tokens': 5, 'cache_read_input_tokens': 900_000}, [])).replace(str(repo), str(plain)) + '\n')
    d = run('--session', f'claude:{sid2}', '--since', f'{since:.3f}')['details']
    check(d['changes'] == {'repo': False} and d['context']['window'] == 1_000_000 and d['context']['used'] == 900_005, 'not a repo; Opus 5.5 is a 1M window')

    # Codex: the rollout found from the UUIDv7 time, its stated window.
    ms = int(iso('2026-10-15T12:00:00Z') * 1000)
    hexms = f'{ms:012x}'
    cid = f'{hexms[:8]}-{hexms[8:12]}-7abc-8def-0123456789ab'
    day = datetime.datetime.fromtimestamp(ms / 1000)
    folder = root / '.codex/sessions' / f'{day:%Y/%m/%d}'; folder.mkdir(parents=True)
    fixture = pathlib.Path(__file__).resolve().parent / 'fixtures/work-session-meter/codex.jsonl'
    (folder / f'rollout-{day:%Y-%m-%dT%H-%M-%S}-{cid}.jsonl').write_text(fixture.read_text())
    d = run('--session', f'codex:{cid}', '--since', f'{since:.3f}')['details']
    check(d['known'] is True and d['context'] == {'used': 233_000, 'window': 258_400, 'model': 'gpt-5-codex'}, 'Codex token_count against its stated window')
    check(d['outputs'] == [] and d['outputsTotal'] == 0, 'Codex outputs that do not exist on this Mac are not listed')

    # Unknown: never a 0%.
    for args in (['--session', f'cursor:{uuid.uuid4()}'], ['--session', 'claude:not-a-uuid'], ['--session', f'claude:{uuid.uuid4()}'],
                 ['--session', f'codex:{uuid.uuid4()}']):
        result = run(*args)
        check(result['ok'] and result['details'] == {'known': False}, f'unknown session {args[1][:7]} reads as unknown')
    proc = subprocess.run([helper, 'work-session-meter'], capture_output=True, env=env, timeout=30)
    check(proc.returncode != 0 and json.loads(proc.stdout)['ok'] is False, 'no session is an error')
    print(f'PASS work session meter helper: {checks} checks; bounded tail, numbers and paths only, read-only git, unknown stays hidden')
finally:
    shutil.rmtree(root)
