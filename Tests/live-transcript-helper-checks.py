#!/usr/bin/env python3
"""live-transcript and live-transcript-status through the COMPILED helper (0.5.278), against fixtures only.

    python3 Tests/live-transcript-helper-checks.py <compiled helper>

The session file is Tests/fixtures/live-transcript/session-6.67.json: the server 6.67 shape with fake text (a silent
index in emptyCompletions, an index still in Whisper, a non-ASCII speaker and text, providerCandidates). It is copied
into a scratch data directory and passed with --data-dir; the real ~/.cos-glasses/data is never read. The session
status runs against a loopback stand-in server with a scratch /tmp home. Prints "live-transcript helper checks: N passed".
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

helper = sys.argv[1]
ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "Tests/fixtures/live-transcript/session-6.67.json"
SID = "meeting_1791635349988_fx67ab"
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-live-transcript-", dir="/tmp"))
data_dir = work / "data"
sessions = data_dir / "active-sessions"
sessions.mkdir(parents=True)
home = work / "home"
(home / ".cos-glasses").mkdir(parents=True, mode=0o700)
token = "b" * 64
(home / ".cos-glasses/.env").write_text("# a comment line that is not shell\nCOS_API_TOKEN=" + token + "\n")
(home / ".cos-glasses/.env").chmod(0o600)
passed = 0
status_answer = {"code": 200, "body": {}}
seen_paths = []


def check(condition, what):
    global passed
    if not condition:
        print("live-transcript helper check FAILED: " + what)
        sys.exit(1)
    passed += 1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        seen_paths.append(self.path)
        if self.path == "/api/health":
            body, code = {"ok": True}, 200
        elif self.headers.get("X-COS-Token") != token:
            body, code = {"error": "unauthorized"}, 401
        else:
            body, code = status_answer["body"], status_answer["code"]
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


server = HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, COS_CONTROL_TEST_HOME=str(home), COS_CONTROL_TEST_API_PORT=str(server.server_port))


def run(*args):
    result = subprocess.run([helper, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=30)
    out, err = result.stdout.decode("utf-8"), result.stderr.decode("utf-8")
    return result.returncode, json.loads(out), out, err


try:
    shutil.copy(FIXTURE, sessions / (SID + ".json"))
    (sessions / ("." + SID + ".json.4242.a1b2c3.tmp")).write_text("{}")
    (sessions / "not a session.json").write_text("{}")
    (sessions / "linked_one.json").symlink_to(sessions / (SID + ".json"))
    (sessions / "noextension12").write_text("{}")
    os.mkfifo(sessions / "fifo_session.json")
    with open(sessions / "huge_session.json", "wb") as huge:
        huge.truncate(65 * 1024 * 1024)

    code, listed, _, err = run("live-transcript", "--data-dir", str(data_dir))
    check(code == 0 and listed["ok"] and err == "", "the list answers ok with nothing on stderr")
    check(sorted(row["sessionId"] for row in listed["details"]["sessions"]) == sorted([SID, "huge_session"]),
          "the list skips temp files, bad names, names without .json, symlinks and FIFOs")
    check(listed["details"]["dataDir"] == str(data_dir) and "read" not in listed["details"], "the list names its data directory and reads no session")

    code, first, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", SID)
    read = first["details"]["read"]
    check(code == 0 and err == "", "a read answers ok with nothing on stderr")
    check([t["i"] for t in read["turns"]] == [0, 1, 2, 3, 5, 7, 8], "chunksIndexed by i, in order; silence and the chunk in flight are absent")
    check(read["maxIndex"] == 8 and read["settledThrough"] == 5 and read["chunkCount"] == 7, "the cursor holds at the chunk still in Whisper")
    check(read["turns"][3]["speaker"] == "Zoë Ångström" and "café" in read["turns"][4]["text"] and "résumé" in read["turns"][4]["text"],
          "non-ASCII speakers and text come through intact")
    check(read["turns"][1]["elapsedMs"] == 6100 and read["startTime"] == 1791635349988, "elapsed in ms, and the start time")
    check(set(read["turns"][0]) == {"i", "elapsedMs", "speaker", "text"}, "each chunk carries only i, elapsedMs, speaker and text")
    check("PHONE-CANDIDATE-TEXT" not in out and "providerCandidates" not in out and '"segments"' not in out and '"words"' not in out,
          "providerCandidates, segments and words never leave the helper")

    code, since, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", SID, "--since", "5")
    check([t["i"] for t in since["details"]["read"]["turns"]] == [7, 8], "--since returns only the later chunks")
    code, same, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", SID, "--since", "5", "--stamp", read["stamp"])
    check(same["details"]["read"]["unchanged"] is True and "turns" not in same["details"]["read"], "the same stamp skips the read")

    # The chunk in flight lands: the file changes, the stamp no longer matches, and the cursor moves past it.
    body = json.loads(FIXTURE.read_text())
    body["chunksIndexed"].insert(5, {"i": 6, "c": {"text": "Fixture late chunk six", "speaker": "Jordan", "elapsed": 36600, "similarity": 0.7}})
    body["asrCompletedIndices"] = [0, 1, 2, 3, 4, 5, 6, 7, 8]
    # Chunk 8 was dropped (a hallucination): completed, no text. It settles its index all the same.
    body["chunksIndexed"][-1]["c"]["text"] = "  "
    (sessions / (SID + ".json")).write_text(json.dumps(body, ensure_ascii=False))
    code, landed, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", SID, "--since", "5", "--stamp", read["stamp"])
    r = landed["details"]["read"]
    check(r["unchanged"] is False and [t["i"] for t in r["turns"]] == [6, 7] and r["settledThrough"] == 8,
          "a late chunk below maxIndex still arrives, because the cursor waited for it")

    for bad in ["..", "a/b", "abc.tmp", "ab", "x" * 97, "../active-sessions/" + SID]:
        code, refused, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", bad)
        check(code != 0 and not refused["ok"] and "invalid_session_id" in refused["message"] and err == "",
              "the session id %r is refused with a reason code" % bad)
    code, refused, _, _ = run("live-transcript", "--data-dir", "relative/data", "--session", SID)
    check(code != 0 and "invalid_data_dir" in refused["message"], "a relative data directory is refused")
    code, refused, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", "linked_one")
    check(code != 0 and "unsafe_file" in refused["message"], "a symlinked session file is refused, never followed")
    link = os.lstat(sessions / "linked_one.json")
    link_stamp = "%d.%d.%d" % (link.st_mtime_ns // 10**9, link.st_mtime_ns % 10**9, link.st_size)
    code, refused, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", "linked_one", "--stamp", link_stamp)
    check(code != 0 and "unsafe_file" in refused["message"], "a symlink is refused even when the stamp matches the link itself")
    code, refused, _, err = run("live-transcript", "--data-dir", str(data_dir), "--session", "fifo_session")
    check(code != 0 and "unsafe_file" in refused["message"], "a FIFO named like a session is refused, and never hangs")
    code, refused, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", "huge_session")
    check(code != 0 and "too_large" in refused["message"], "a file over 64 MB is refused unread")
    code, gone, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", "meeting_gone_session")
    check(code == 0 and gone["details"]["read"]["ended"] is True, "a missing file reads as ended")

    (sessions / (SID + ".json")).write_text('{"sessionId":"' + SID + '","chunksIndexed":[{"i":0,"c":{"text":"SECRET-TRANSCRIPT-WORDS')
    code, broken, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", SID)
    check(code != 0 and "parse_failed" in broken["message"], "a torn file is a reason code")
    check("SECRET-TRANSCRIPT-WORDS" not in out + err, "a failure never carries transcript text, on stdout or stderr")
    check(not (home / "Library/Logs").exists() or "SECRET-TRANSCRIPT-WORDS" not in "".join(
        p.read_text(errors="replace") for p in (home / "Library/Logs").rglob("*") if p.is_file()), "nothing reaches the helper log")

    status_answer["body"] = {"sessionId": SID, "state": "saved", "receivedCount": 9, "canonicalRanges": [[0, 3], [5, 8]],
                             "saveReceipt": {"saved": True, "filename": "2026-10-10_G2_Recording_x.md", "filepath": "recordings/2026-10/x.md"}}
    code, saved, out, err = run("live-transcript-status", "--session", SID)
    check(code == 0 and saved["details"] == {"sessionId": SID, "state": "saved", "savedFilename": "2026-10-10_G2_Recording_x.md"},
          "the session status keeps the state and the saved filename only")
    check(seen_paths[-1] == "/api/meeting/sessions/%s/status" % SID, "the status asks the server's own route")
    status_answer["body"] = {"sessionId": SID, "state": "closed"}
    code, closed, _, _ = run("live-transcript-status", "--session", SID)
    check(code == 0 and closed["details"]["state"] == "closed", "a closed session says closed")
    status_answer["code"] = 404
    code, absent, _, _ = run("live-transcript-status", "--session", SID)
    check(code == 0 and absent["details"]["reason"] == "route_absent", "an older server is route_absent, not a failure")
    status_answer["code"] = 500
    code, failed, _, _ = run("live-transcript-status", "--session", SID)
    check(code != 0 and "http_500" in failed["message"], "a server error is a reason code")
    before = len(seen_paths)
    code, refused, _, _ = run("live-transcript-status", "--session", "../etc")
    check(code != 0 and "invalid_session_id" in refused["message"] and len(seen_paths) == before, "a bad id never reaches the server")
    print("live-transcript helper checks: %d passed" % passed)
finally:
    server.shutdown()
    shutil.rmtree(work, ignore_errors=True)
