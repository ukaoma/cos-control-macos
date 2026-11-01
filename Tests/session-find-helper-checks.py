#!/usr/bin/env python3
"""The ⌘K meaning search verb (0.5.362), through the compiled helper, against a stand-in server on loopback.

    python3 Tests/session-find-helper-checks.py <compiled helper>

A scratch home under /tmp (COS_CONTROL_TEST_HOME) holds a fictional token. The stand-in server plays the contract's route
(`POST /api/agent-sessions/find`) and `GET /api/decision-provider`. No provider is asked, no real session is read, no key exists.
What it holds:
  - the verb takes JSON on stdin and nothing else: a body with a wrong key, a short or long query, a provider that is not Jev or SubQ,
    or a stage that is not first or full never reaches the server;
  - what reaches the server is the body, with the token header, and nothing from the command line;
  - the answer is read in its own shape: rows keep their session fields, a probability from 0 to 1, one of three strength words (any
    other word reads as possible), the judged text cut, and the last activity date; a row without a probability is dropped; at most 8;
  - every failure is an answer with a fixed reason: no token, an unreachable server, a 404 (an older server), a 503 (try later), an
    answer that is not the contract's, a reason code that is not a code, and a server that takes longer than 7 s (timed_out, inside 8 s);
  - the decision provider's capabilities reach Control as the one boolean it asks for, and nothing else of them;
  - the words never appear in the helper's output or in its error text.
Each check names its behaviour.
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

helper = str(pathlib.Path(sys.argv[1]).resolve())
home = pathlib.Path(tempfile.mkdtemp(prefix="cos-find-helper-", dir="/tmp"))
token = "c" * 64
(home / ".cos-glasses").mkdir(mode=0o700)
(home / ".cos-glasses/.env").write_text("COS_API_TOKEN=" + token + "\n")
(home / ".cos-glasses/.env").chmod(0o600)
decoy = pathlib.Path(tempfile.mkdtemp(prefix="cos-find-decoy-", dir="/tmp"))
failures, ran = [], 0
calls = []
state = {"status": 200, "body": None, "sleep": 0, "capabilities": {"sessionFind": True, "other": "x"}}
WORDS = "persona pricing for the jewelry tier"


def check(ok, name, detail=""):
    global ran
    ran += 1
    if not ok:
        failures.append(f"{name}: {detail}")


def row(session, title, probability, strength="likely", **extra):
    base = {"session_id": session, "provider": "claude", "display_label": title, "project": "Quilt-Software", "created": "2026-10-20T10:00:00.000Z",
            "modified": "2026-10-21T10:00:00.000Z", "alive": False, "state": "recent", "pinned": False, "last_activity_at": "2026-10-29T16:30:00.000Z",
            "judged_text": "price the jewelry persona tier above the base plan", "probability": probability, "strength": strength, "compressed": False}
    base.update(extra)
    return base


def answer(rows, **extra):
    base = {"available": True, "reason": None, "message": "", "provider": "jev", "storesData": False, "rows": rows, "asked": 254,
            "reachedBack": "2026-09-17T00:00:00.000Z", "skipped": 0, "cached": False}
    base.update(extra)
    return base


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        calls.append((self.command, self.path, body, self.headers.get("X-COS-Token"), self.headers.get("Content-Type")))
        if state["sleep"]:
            time.sleep(state["sleep"])
        self.reply(state["status"], state["body"])

    def do_GET(self):
        calls.append((self.command, self.path, None, self.headers.get("X-COS-Token"), None))
        settings = {"schema": 1, "revision": "b" * 64, "provider": "jev", "overrides": {}, "saved": {"provider": None, "overrides": {}},
                    "effective": {"session": "jev", "completion": "jev", "search": "jev"}, "sources": {"session": "default", "completion": "default", "search": "default"},
                    "configured": {"jev": True, "subq": False}, "models": {"jev": "jev-1.13.0", "subq": "subq-snap-preview"}}
        if state["capabilities"] is not None:
            settings["capabilities"] = state["capabilities"]
        self.reply(200, settings)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
base_env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port), CFFIXED_USER_HOME=str(decoy), HOME=str(decoy))
for name in ("COS_WORK_CONNECTED_TEST", "COS_WORK_REVIEW_CANDIDATE_PORT", "COS_WORK_REVIEW_CANDIDATE_TOKEN_FILE"):
    base_env.pop(name, None)


def run(command, body=None, env=None, wait=30):
    started = time.time()
    result = subprocess.run([helper, command], input=json.dumps(body).encode() if body is not None else b"", capture_output=True, env=env or base_env, timeout=wait)
    out, err = result.stdout.decode(), result.stderr.decode()
    check(WORDS not in out and WORDS not in err, "[the words are never echoed]", command)
    check(token not in out and token not in err, "[the token is never echoed]", command)
    try:
        parsed = json.loads(out or "{}")
    except ValueError:
        parsed = {}
    return result.returncode, parsed, out, time.time() - started


def find(body=None, **kw):
    return run("agent-sessions-find", {"query": WORDS, "consentedProvider": "jev", "stage": "first"} if body is None else body, **kw)


try:
    # The good body reaches the route, exactly, with the token and as JSON.
    state["body"] = answer([row("1111aaaa-0000-4000-8000-000000000001", "Jewelry persona review", 0.82, "strong")])
    code, got, _, _ = find()
    sent = [c for c in calls if c[1] == "/api/agent-sessions/find"]
    check(code == 0 and got.get("ok") is True and len(sent) == 1, "[a good body reaches the route once]", f"{code} {got} {len(sent)}")
    check(sent[0][0] == "POST" and sent[0][2] == {"query": WORDS, "consentedProvider": "jev", "stage": "first"}, "[the route gets the body exactly]", str(sent[0][2]))
    check(sent[0][3] == token and sent[0][4] == "application/json", "[the token is the header and the body is JSON]", str(sent[0][3:]))
    details = got.get("details", {})
    check(details.get("available") is True and details.get("provider") == "jev" and details.get("asked") == 254 and details.get("skipped") == 0, "[the answer carries its counts]", str(details))
    check(details.get("reachedBack") == "2026-09-17T00:00:00.000Z" and details.get("storesData") is False and details.get("cached") is False, "[the answer carries how far back it read]", str(details))
    rows = details.get("rows", [])
    r = rows[0] if rows else {}
    check(len(rows) == 1 and r.get("id") == "1111aaaa-0000-4000-8000-000000000001" and r.get("provider") == "claude" and r.get("name") == "Jewelry persona review", "[a row keeps its session fields]", str(r))
    check(r.get("probability") == 0.82 and r.get("strength") == "strong" and r.get("compressed") is False, "[a row carries its probability, strength and compression]", str(r))
    check(r.get("judgedText") == "price the jewelry persona tier above the base plan", "[a row carries the text it was judged on]", str(r))
    check(r.get("updatedAt") == "2026-10-29T16:30:00.000Z" and r.get("lastActivityAt") == "2026-10-29T16:30:00.000Z", "[a row's date is its last activity, not the file time]", str(r))
    check("snippet" not in r, "[a row has no keyword snippet]", str(r))

    # Bodies the helper refuses before the server sees them.
    before = len(calls)
    bad_bodies = [
        {"query": WORDS, "consentedProvider": "jev"},
        {"query": WORDS, "consentedProvider": "jev", "stage": "first", "extra": 1},
        {"query": "ab", "consentedProvider": "jev", "stage": "first"},
        {"query": "   ab   ", "consentedProvider": "jev", "stage": "first"},
        {"query": "x" * 201, "consentedProvider": "jev", "stage": "first"},
        {"query": WORDS, "consentedProvider": "openai", "stage": "first"},
        {"query": WORDS, "consentedProvider": None, "stage": "first"},
        {"query": WORDS, "consentedProvider": "jev", "stage": "all"},
        {"query": 5, "consentedProvider": "jev", "stage": "first"},
        {"query": WORDS, "consentedProvider": True, "stage": "first"},
        [WORDS],
    ]
    for body in bad_bodies:
        code, got, _, _ = find(body)
        check(code != 0 or got.get("ok") is False, "[a malformed body is refused]", str(body)[:60])
    code, got, _, _ = run("agent-sessions-find", None)
    check(code != 0 or got.get("ok") is False, "[an empty body is refused]", "")
    check(len(calls) == before, "[a refused body never reaches the server]", f"{len(calls) - before} calls")
    # 200 code points is allowed, counted as the server counts (a code point, not a byte).
    state["body"] = answer([])
    code, got, _, _ = find({"query": "é" * 200, "consentedProvider": "subq", "stage": "full"})
    check(got.get("ok") is True and calls[-1][2]["consentedProvider"] == "subq" and calls[-1][2]["stage"] == "full", "[200 code points, the second provider and the full stage go through]", str(got)[:120])

    # The words only ever arrive on stdin.
    result = subprocess.run([helper, "agent-sessions-find", WORDS], input=json.dumps({"query": WORDS, "consentedProvider": "jev", "stage": "first"}).encode(),
                            capture_output=True, env=base_env, timeout=30)
    check(WORDS.encode() not in result.stdout + result.stderr, "[words as an argument are not echoed]", "")

    # Rows: whitelisted strength, a row with no probability is dropped, at most 8, bounded text.
    many = [row(f"2222aaaa-0000-4000-8000-{i:012d}", f"Session {i}", 0.9 - i * 0.05, "strong" if i == 0 else "likely") for i in range(11)]
    many[1]["strength"] = "very_strong"
    many[2]["strength"] = None
    many[3]["probability"] = None
    many[4]["probability"] = 1.4
    many[5]["probability"] = True
    many[6]["judged_text"] = "t" * 900
    many[7]["compressed"] = "yes"
    many[7]["last_activity_at"] = "yesterday, around lunch"
    state["body"] = answer(many)
    _, got, _, _ = find()
    rows = got["details"]["rows"]
    ids = [x["id"] for x in rows]
    check(len(rows) <= 8, "[at most 8 rows]", str(len(rows)))
    check(all(x["strength"] in ("strong", "likely", "possible") for x in rows), "[strength is one of three words]", str([x["strength"] for x in rows]))
    check(next(x for x in rows if x["name"] == "Session 1")["strength"] == "possible" and next(x for x in rows if x["name"] == "Session 2")["strength"] == "possible", "[an unknown strength reads as possible]", "")
    check(not any(x["name"] in ("Session 3", "Session 4", "Session 5") for x in rows), "[a row without a usable probability is dropped]", str([x["name"] for x in rows]))
    check(len(next(x for x in rows if x["name"] == "Session 6")["judgedText"]) == 400, "[judged text is cut]", "")
    seven = next(x for x in rows if x["name"] == "Session 7")
    check(seven["compressed"] is False and "lastActivityAt" not in seven and seven["updatedAt"] == "2026-10-21T10:00:00.000Z", "[a bad flag is false and a bad date is not taken]", str(seven))
    check([x["probability"] for x in rows] == sorted((x["probability"] for x in rows), reverse=True), "[rows keep the server's order]", str([x["probability"] for x in rows]))
    check(len(set(ids)) == len(ids), "[one row per session]", "")

    # Twelve good rows: eight are kept, in the server's order.
    state["body"] = answer([row(f"6666aaaa-0000-4000-8000-{i:012d}", f"Good {i}", 0.9 - i * 0.02) for i in range(12)])
    _, got, _, _ = find()
    check([x["name"] for x in got["details"]["rows"]] == [f"Good {i}" for i in range(8)], "[at most 8 rows, the first eight]", str(len(got["details"]["rows"])))

    # A title and a project are one line each, and an answer far bigger than the contract's is not read.
    state["body"] = answer([row("4444aaaa-0000-4000-8000-000000000004", "T" * 900, 0.5, project="P" * 600)])
    _, got, _, _ = find()
    r = got["details"]["rows"][0]
    check(len(r["name"]) == 300 and len(r["workspace"]) <= 200, "[a title and a project are bounded]", f"{len(r['name'])} {len(r['workspace'])}")
    state["body"] = answer([row("5555aaaa-0000-4000-8000-000000000005", "Big", 0.5, judged_text="j" * 400, filler="z" * 300_000)])
    _, got, _, _ = find()
    check(got["details"] == {"available": False, "reason": "failed"}, "[an answer far bigger than the contract's is not read]", str(got["details"])[:120])

    # A compressed row: no file, the flag carries.
    state["body"] = answer([row("rollout-2026-10-01T09-00-00-3333aaaa-0000-4000-8000-000000000003", "Quarterly planning", 0.71, "strong", provider="codex", compressed=True)])
    _, got, _, _ = find()
    r = got["details"]["rows"][0]
    check(r["compressed"] is True and r["provider"] == "codex" and "file" not in r and "path" not in r, "[a compressed row says so and carries no file]", str(r))

    # Nothing close, capped and the other definitive reasons, in their own shape.
    state["body"] = answer([], asked=254, skipped=3)
    _, got, _, _ = find()
    d = got["details"]
    check(d["available"] is True and d["rows"] == [] and d["asked"] == 254 and d["skipped"] == 3, "[nothing close keeps what was asked and skipped]", str(d))
    for reason in ("consent_required", "provider_changed", "decision_not_configured", "sessions_off", "find_off", "cap_reached", "breaker_open", "query_too_short", "failed", "jev_not_configured"):
        state["body"] = {"available": False, "reason": reason, "message": "words with " + WORDS, "rows": []}
        _, got, out, _ = find()
        check(got["details"] == {"available": False, "asked": 0, "skipped": 0, "cached": False, "reason": reason, "rows": []}, f"[{reason} is an answer with its reason only]", str(got["details"]))
        check("words with" not in out, "[the server's message is not forwarded]", reason)
    state["body"] = {"available": False, "reason": "Not A Code!", "rows": []}
    _, got, _, _ = find()
    check(got["details"]["reason"] == "failed", "[a reason that is not a code reads as failed]", str(got["details"]))
    state["body"] = {"available": False, "reason": "cap_reached", "resetsAt": "2026-11-02T00:00:00.000Z"}
    _, got, _, _ = find()
    check(got["details"].get("resetsAt") == "2026-11-02T00:00:00.000Z", "[a reset time the server names is carried]", str(got["details"]))
    state["body"] = {"available": False, "reason": "cap_reached", "resetsAt": "soon, ish"}
    _, got, _, _ = find()
    check("resetsAt" not in got["details"], "[a reset time that is not a date is dropped]", str(got["details"]))
    state["body"] = {"rows": []}
    _, got, _, _ = find()
    check(got["details"] == {"available": False, "reason": "failed"}, "[an answer that is not the contract's reads as failed]", str(got["details"]))
    state["body"] = {"available": True, "rows": "all of them"}
    _, got, _, _ = find()
    check(got["details"] == {"available": False, "reason": "failed"}, "[rows that are not rows read as failed]", str(got["details"]))
    state["body"] = answer([], provider="openai")
    _, got, _, _ = find()
    check("provider" not in got["details"], "[a provider that is not Jev or SubQ is dropped]", str(got["details"]))

    # Status codes.
    for status, reason in ((404, "server_too_old"), (503, "try_later"), (401, "unauthorized"), (403, "unauthorized"), (500, "failed"), (400, "failed")):
        state["status"], state["body"] = status, {"error": {"code": "something_else", "message": WORDS}}
        code, got, out, _ = find()
        check(code == 0 and got["ok"] is True and got["details"] == {"available": False, "reason": reason}, f"[HTTP {status} reads as {reason}]", str(got))
    state["status"] = 200

    # A server that does not answer in time: timed_out, inside the 8 s the app allows, and a stopped server: unreachable.
    state["body"], state["sleep"] = answer([]), 10
    code, got, _, seconds = find(wait=20)
    check(got.get("details", {}).get("reason") == "timed_out" and seconds < 8.0, "[a server that takes too long is timed_out inside 8 seconds]", f"{got} {seconds:.1f}s")
    state["sleep"] = 0
    dead = dict(base_env, COS_CONTROL_TEST_API_PORT=str(server.server_port + 1 if server.server_port < 65000 else server.server_port - 1))
    code, got, _, seconds = find(env=dead, wait=20)
    check(got.get("details", {}) == {"available": False, "reason": "unreachable"} and seconds < 6.0, "[a stopped server is unreachable, at once]", f"{got} {seconds:.1f}s")

    # No token: an answer, and no request.
    (home / ".cos-glasses/.env").unlink()
    before = len(calls)
    code, got, _, _ = find()
    check(code == 0 and got.get("ok") is True and got["details"] == {"available": False, "reason": "no_token"} and len(calls) == before, "[a missing token is an answer and asks nothing]", str(got))
    (home / ".cos-glasses/.env").write_text("COS_API_TOKEN=" + token + "\n")
    (home / ".cos-glasses/.env").chmod(0o600)

    # Capabilities: the one boolean, by name.
    state["capabilities"] = {"sessionFind": True, "somethingElse": "x", "token": token}
    _, got, out, _ = run("decision-provider-status")
    check(got["details"].get("capabilities") == {"sessionFind": True} and token not in out, "[the capability reaches Control as one boolean and nothing else]", str(got["details"].get("capabilities")))
    state["capabilities"] = {"sessionFind": False}
    _, got, _, _ = run("decision-provider-status")
    check(got["details"].get("capabilities") == {"sessionFind": False}, "[a server that says no is read as no]", str(got["details"].get("capabilities")))
    for odd in ({"sessionFind": "true"}, {"sessionFind": 1}, {}, "yes", None):
        state["capabilities"] = odd
        _, got, _, _ = run("decision-provider-status")
        check("capabilities" not in got["details"], "[anything but a real boolean is no capability]", str(odd))
finally:
    server.shutdown()
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(decoy, ignore_errors=True)

if failures:
    for failure in failures:
        print("session find helper check failed " + failure, file=sys.stderr)
    sys.exit(1)
print(f"PASS session find helper: {ran} checks (stdin only, strict body, rows in the contract's shape, three strength words, fixed reasons, 7 s deadline, a missing token is an answer, one capability boolean, no words or token echoed)")
