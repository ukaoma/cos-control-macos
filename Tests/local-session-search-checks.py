#!/usr/bin/env python3
"""The ⌘K local word search and the open path it reaches, through the compiled helper, against a fixture home.

    python3 Tests/local-session-search-checks.py <compiled helper>

A scratch home under /tmp (COS_CONTROL_TEST_HOME) holds fictional Claude Desktop records and transcripts. Nothing real is read, no
server is asked, nothing is opened. What it holds (0.5.361, QA items 3 and 14):
  - a Desktop record whose cliSessionId differs from its own id is found once, by its title and by a word inside its transcript,
    under the id its transcript carries, so it lists once and opens;
  - session-reveal resolves that id (and a transcript's short id) to the record, and refuses a short id it cannot place;
  - a record whose cliSessionId is its own id, and a record with no transcript, do the same;
  - the words reach the helper only on stdin, a too-short query is refused, and a query that is `--local` is not a flag.
Each check names its behaviour.
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, time, uuid

helper = str(pathlib.Path(sys.argv[1]).resolve())
home = pathlib.Path(tempfile.mkdtemp(prefix="cos-local-search-", dir="/tmp"))
# The process's own HOME is an empty decoy, so a read of the real home directory finds nothing (COS_CONTROL_TEST_HOME is the fixture).
decoy = pathlib.Path(tempfile.mkdtemp(prefix="cos-local-decoy-", dir="/tmp"))
failures, ran = [], 0


def check(ok, name, detail=""):
    global ran
    ran += 1
    if not ok:
        failures.append(f"{name}: {detail}")


def make_record(rec_id, cli_id, title, cwd):
    folder = home / "Library/Application Support/Claude/claude-code-sessions/acct/workspace"
    folder.mkdir(parents=True, exist_ok=True)
    body = {"sessionId": "local_" + rec_id, "cliSessionId": cli_id, "cwd": cwd, "title": title, "isArchived": False}
    (folder / f"local_{rec_id}.json").write_text(json.dumps(body))


def make_transcript(cli_id, project, words):
    folder = home / ".claude/projects" / project
    folder.mkdir(parents=True, exist_ok=True)
    line = {"type": "user", "message": {"role": "user", "content": words}}
    (folder / f"{cli_id}.jsonl").write_text(json.dumps(line) + "\n")


def run(args, stdin=""):
    env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), CFFIXED_USER_HOME=str(decoy), HOME=str(decoy))
    started = time.time()
    result = subprocess.run([helper] + args, input=stdin.encode(), capture_output=True, env=env, timeout=60)
    try:
        answer = json.loads(result.stdout.decode() or "{}")
    except ValueError:
        answer = {}
    return result.returncode, answer, result.stderr.decode(), time.time() - started


def search(words):
    code, answer, err, _ = run(["claude-sessions-search", "--local", "--limit", "20"], words)
    return code, answer.get("details", {}).get("hits", []), answer, err


try:
    r1, c1 = str(uuid.uuid4()), str(uuid.uuid4())     # a record whose cliSessionId differs from its id, with a transcript
    r2, c2 = str(uuid.uuid4()), str(uuid.uuid4())     # a record whose cliSessionId differs, with no transcript
    r3 = str(uuid.uuid4())                            # a record that is its own cliSessionId, with a transcript
    t4 = str(uuid.uuid4())                            # a transcript with no record at all
    make_record(r1, c1, "Zebra pricing review", "/tmp/fx/zebra-site")
    make_transcript(c1, "-tmp-fx-zebra-site", "we compared giraffecrossing numbers for the quarter")
    make_record(r2, c2, "Okapi planning notes", "/tmp/fx/okapi-site")
    make_record(r3, r3, "Narwhal budget", "/tmp/fx/narwhal-site")
    make_transcript(r3, "-tmp-fx-narwhal-site", "the kelpforest line needs a second column")
    make_transcript(t4, "-tmp-fx-loose", "an unnamed session about dandelionwine tasting")
    # A transcript whose first 96 KB window ends inside a two-byte character: the strict decode dropped the whole file (QA item 5).
    t5 = str(uuid.uuid4())
    folder = home / ".claude/projects/-tmp-fx-cut"
    folder.mkdir(parents=True, exist_ok=True)
    first = json.dumps({"type": "user", "message": {"role": "user", "content": "a note about pelicanbriefing at the start"}}) + "\n"
    pad = "" if len(first.encode()) % 2 == 1 else " "
    first = first.replace("note", "note" + pad, 1)
    assert len(first.encode()) % 2 == 1
    (folder / f"{t5}.jsonl").write_bytes(first.encode() + ("\u00e9" * 80000).encode())

    # A body word: one hit, under the transcript's own id, with the record's title. The record is not listed a second time.
    code, hits, _, _ = search("giraffecrossing")
    check(code == 0 and len(hits) == 1, "a word inside a transcript finds its session once", f"{len(hits)} hits")
    if hits:
        check(hits[0]["id"].lower() == c1, "the hit carries the id its transcript carries, not the record's", hits[0]["id"])
        check(hits[0]["name"] == "Zebra pricing review" and hits[0].get("workspace", "") != "", "the hit has the record's title and a project", str(hits[0].get("name")))
    # A title word: the same session, still once, though both its record row and its transcript row exist.
    code, hits, _, _ = search("zebra")
    check(len(hits) == 1 and hits[0]["id"].lower() == c1, "a title word finds a record whose cliSessionId differs once, under the transcript's id", str([h["id"] for h in hits]))
    # A record with no transcript: found by its title under its cliSessionId, which is what open resolves.
    code, hits, _, _ = search("okapi")
    check(len(hits) == 1 and hits[0]["id"].lower() == c2, "a record with no transcript is found once, under its cliSessionId", str([h["id"] for h in hits]))
    # A record that is its own cliSessionId, and a transcript with no record.
    code, hits, _, _ = search("kelpforest")
    check(len(hits) == 1 and hits[0]["id"].lower() == r3, "a record that is its own cliSessionId is found once", str([h["id"] for h in hits]))
    code, hits, _, _ = search("dandelionwine")
    check(len(hits) == 1 and hits[0]["id"].lower() == t4, "a transcript with no record is found under its full id", str([h["id"] for h in hits]))
    code, hits, _, _ = search("pelicanbriefing")
    check(len(hits) == 1 and hits[0]["id"].lower() == t5, "a window cut inside a character still reads the start of the file", str([h["id"] for h in hits]))
    # Nothing lists twice for a word every session shares.
    for rec in (r1, r2, r3):
        pass
    code, hits, _, _ = search("zebra okapi narwhal")
    keys = [h["id"].lower()[:8] for h in hits]
    check(len(keys) == len(set(keys)), "no session lists twice, whatever the words", str(keys))

    # QA item 12: the same words always give the same rows, a named row takes the date and project of its dated row, and a transcript
    # past the titled newest 20 still says what it is and where it is.
    def make_aged_transcript(session_id, project, words, age_seconds):
        make_transcript(session_id, project, words)
        stamp = time.time() - age_seconds
        os.utime(home / ".claude/projects" / project / f"{session_id}.jsonl", (stamp, stamp))

    tie_new, tie_old = str(uuid.uuid4()), str(uuid.uuid4())
    make_aged_transcript(tie_old, "-tmp-fx-GitHub-tie-site", "tiebreakword shared opening line", 3600)
    make_aged_transcript(tie_new, "-tmp-fx-GitHub-tie-site", "tiebreakword shared opening line", 60)
    orders = []
    for _ in range(8):
        code, hits, _, _ = search("tiebreakword")
        orders.append([h["id"].lower() for h in hits])
    check(all(order == [tie_new, tie_old] for order in orders), "equal scores order newest first, in every process", str(orders[:2]))

    codex_id = str(uuid.uuid4())
    codex_folder = home / ".codex/sessions/2026/10/31"
    codex_folder.mkdir(parents=True, exist_ok=True)
    meta = {"type": "session_meta", "payload": {"id": codex_id, "cwd": "/tmp/fx/codex-site", "timestamp": "2026-10-31T10:00:00Z"}}
    said = {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "ibexcrossing notes for the plan"}]}}
    (codex_folder / f"rollout-2026-10-31T10-00-00-{codex_id}.jsonl").write_text(json.dumps(meta) + "\n" + json.dumps(said) + "\n")
    (home / ".codex/session_index.jsonl").write_text(json.dumps({"id": codex_id, "thread_name": "Ibex migration notes"}) + "\n")
    code, hits, _, _ = search("ibex migration")
    check(len(hits) == 1 and hits[0]["id"].lower() == codex_id, "a named Codex session is found once", str([h["id"] for h in hits]))
    if hits:
        check(hits[0].get("workspace") == "codex-site" and hits[0].get("updatedAt"), "a named Codex row takes the project and date of its dated row", str({k: hits[0].get(k) for k in ("workspace", "updatedAt")}))

    quokka = str(uuid.uuid4())
    make_aged_transcript(quokka, "-tmp-fx-GitHub-quokka-site", "Plan the quokka forecasts\nquokkaweather needs a second look", 3 * 24 * 3600)
    for _ in range(22):
        make_aged_transcript(str(uuid.uuid4()), "-tmp-fx-GitHub-filler-site", "fillerwords about nothing in particular", 30)
    code, hits, _, _ = search("quokkaweather")
    check(len(hits) == 1 and hits[0]["id"].lower() == quokka, "a transcript past the newest 20 is found by its words", str([h["id"] for h in hits]))
    if hits:
        check(hits[0].get("workspace") == "quokka-site", "a transcript past the newest 20 has its project from its folder", str(hits[0].get("workspace")))
        check(hits[0].get("name") not in ("", "Claude session") and "quokka" in str(hits[0].get("name")).lower(), "a transcript past the newest 20 has a title, not Claude session", str(hits[0].get("name")))

    # QA item 13: the snippet window never begins or ends inside a key, so a key's head or tail is not what shows.
    key = ("A1b2C3d4E5" * 6)[:60]
    windowed = str(uuid.uuid4())
    make_transcript(windowed, "-tmp-fx-GitHub-window-site", "intro words " + key + " fillerfill windowtoken here and a long run of padding words after it to fill the rest of the snippet window past one hundred and eighty characters")
    code, hits, _, _ = search("windowtoken")
    check(len(hits) == 1 and "windowtoken" in str(hits[0].get("snippet")), "a snippet keeps the words it matched", str([h.get("snippet") for h in hits])[:120])
    if hits:
        snippet = str(hits[0].get("snippet"))
        check(not any(key[-n:] in snippet for n in range(8, 61)), "a snippet never begins inside a key", snippet[:80])
    head_key = ("Z9y8X7w6V5" * 6)[:60]
    tailed = str(uuid.uuid4())
    make_transcript(tailed, "-tmp-fx-GitHub-tail-site", "intro words tailtoken " + "pad " * 32 + head_key + " end of the line")
    code, hits, _, _ = search("tailtoken")
    check(len(hits) == 1 and "tailtoken" in str(hits[0].get("snippet")), "a snippet keeps the words it matched, whichever end is cut", str([h.get("snippet") for h in hits])[:120])
    if hits:
        snippet = str(hits[0].get("snippet"))
        check(not any(head_key[:n] in snippet for n in range(8, 61)), "a snippet never ends inside a key", snippet[-80:])

    # The open path: reveal resolves each id to the record. With Claude Desktop installed the link is the continue link; without it the
    # reason says so. The one thing it must never say is that the id is incomplete.
    def reveal(session):
        code, answer, err, _ = run(["session-reveal", "--provider", "claude", "--session", session])
        details = answer.get("details", {})
        return code, details.get("deepLink"), details.get("revealReason")

    for name, session, record in (("a record with a transcript, by its cliSessionId", c1, r1), ("a record with no transcript, by its cliSessionId", c2, r2),
                                  ("a record with a transcript, by the transcript's short id", c1[:8], r1)):
        code, link, reason = reveal(session)
        ok = code == 0 and reason != "invalid" and (link is None or link == f"claude://code/continue?session=local_{record}")
        check(ok, f"open resolves {name}", f"code {code} reason {reason}")
        check(reason in ("desktop", "no_desktop", "desktop_too_old") or link is not None, f"open reaches a record or says why not, for {name}", f"reason {reason}")
    code, link, reason = reveal(c2[:8])
    check(reason == "invalid" or reason == "no_transcript", "a short id that only a record names is not guessed at", f"reason {reason}")
    code, link, reason = reveal(str(uuid.uuid4())[:8])
    check(reason in ("invalid", "no_transcript"), "a short id that names nothing is refused", f"reason {reason}")

    # The words go on stdin only; too few are refused; a query that spells the flag is a query.
    code, answer, err, _ = run(["claude-sessions-search", "--local"], "ab")
    check(code != 0 or answer.get("ok") is False, "two characters are refused", f"code {code}")
    code, hits, answer, err = search("giraffecrossing" * 20)
    check(code == 0 and answer.get("ok") is True, "a long query is cut, not refused", f"code {code}")
    code, answer, err, _ = run(["claude-sessions-search", "--local", "--limit", "5", "--query", "giraffecrossing"], "")
    check(code != 0 or answer.get("ok") is False or not answer.get("details", {}).get("hits"), "an argument is not a query: nothing on stdin finds nothing", f"code {code}")
    check("giraffecrossing" not in err, "the words never reach stderr", err[:80])
finally:
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(decoy, ignore_errors=True)

if failures:
    for failure in failures:
        print("Local session search check FAILED: " + failure, file=sys.stderr)
    sys.exit(1)
print(f"PASS: local session search, {ran} checks")
