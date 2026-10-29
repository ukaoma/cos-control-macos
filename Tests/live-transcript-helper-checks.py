#!/usr/bin/env python3
"""live-transcript and live-transcript-status through the COMPILED helper (0.5.278), against fixtures only.

    python3 Tests/live-transcript-helper-checks.py <compiled helper>

The session file is Tests/fixtures/live-transcript/session-6.67.json: the server 6.67 shape with fake text (a silent
index in emptyCompletions, an index still in Whisper, a non-ASCII speaker and text, providerCandidates). It is copied
into a scratch data directory and passed with --data-dir; the real ~/.cos-glasses/data is never read. The session
status runs against a loopback stand-in server with a scratch /tmp home. Prints "live-transcript helper checks: N passed".
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile, threading
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
    # A name without .json whose first part names a real session file must not list that session twice.
    shutil.copy(FIXTURE, sessions / "meeting_dupe.json")
    (sessions / "meeting_dupeabcde").write_text("{}")
    os.mkfifo(sessions / "fifo_session.json")
    with open(sessions / "huge_session.json", "wb") as huge:
        huge.truncate(65 * 1024 * 1024)

    code, listed, _, err = run("live-transcript", "--data-dir", str(data_dir))
    check(code == 0 and listed["ok"] and err == "", "the list answers ok with nothing on stderr")
    check(sorted(row["sessionId"] for row in listed["details"]["sessions"]) == sorted([SID, "huge_session", "meeting_dupe"]),
          "the list skips temp files, bad names, names without .json, symlinks and FIFOs")
    check(listed["details"]["dataDir"] == str(data_dir) and "read" not in listed["details"], "the list names its data directory and reads no session")

    code, first, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", SID)
    read = first["details"]["read"]
    check(code == 0 and err == "", "a read answers ok with nothing on stderr")
    check([t["i"] for t in read["turns"]] == [0, 1, 2, 3, 5, 7, 8], "chunksIndexed by i, in order; silence and the chunk in flight are absent")
    check(read["maxIndex"] == 8 and read["settledThrough"] == 5 and "chunkCount" not in read, "the cursor holds at the chunk still in Whisper")
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
    check("levels" not in read and "levels" not in r, "a 6.86.0 file (no chunkLevels) reads with no levels")

    # 0.5.339 (server 6.87.0): the file's chunkLevels cross as three numbers a chunk, in index order, the newest 120.
    body["chunkLevels"] = [{"i": 4, "level": 0.105, "speechSec": 0.04}, {"i": 1, "level": 0.714, "speechSec": 3.2, "text": "SECRET-LEVEL-TEXT"},
                           {"i": 2, "level": 0.3, "speechSec": None}, {"i": 3, "level": 7, "speechSec": 1}, {"i": 5, "level": True, "speechSec": 1}]
    body["chunkLevels"] += [{"i": 10 + n, "level": 0.5, "speechSec": 2} for n in range(130)]
    (sessions / (SID + ".json")).write_text(json.dumps(body, ensure_ascii=False))
    code, levelled, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", SID, "--since", "8")
    levels = levelled["details"]["read"]["levels"]
    check(code == 0 and err == "" and len(levels) == 120 and levels[0]["i"] == 20 and levels[-1]["i"] == 139,
          "chunkLevels: the newest 120, in index order")
    check(all(set(entry) == {"i", "level", "speechSec"} for entry in levels) and "SECRET-LEVEL-TEXT" not in out, "each level is three numbers, nothing else")
    body["chunkLevels"] = body["chunkLevels"][:5]
    (sessions / (SID + ".json")).write_text(json.dumps(body, ensure_ascii=False))
    code, few, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", SID, "--since", "8")
    check(few["details"]["read"]["levels"] == [{"i": 1, "level": 0.714, "speechSec": 3.2}, {"i": 2, "level": 0.3, "speechSec": None},
                                               {"i": 4, "level": 0.105, "speechSec": 0.04}],
          "a level outside 0 to 1, or not a number, is dropped; null speech seconds stays null")

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
    check(code == 0 and saved["details"] == {"sessionId": SID, "state": "saved"},
          "the session status keeps the state only (the saved meeting is found by session id)")
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
    # Future phone consumer: synthetic, isolated registry/policy/journal only.
    phone = json.loads((ROOT / "Tests/fixtures/phone-meeting/session.json").read_text())
    phone_id = phone["sessionId"]
    phone_path = sessions / (phone_id + ".json")
    registry_dir = data_dir / "phone-recordings"; registry_dir.mkdir()
    policy_dir = data_dir / "speaker-policy"; policy_dir.mkdir()
    registry_path = registry_dir / (phone_id + ".json")
    policy_path = policy_dir / (hashlib.sha256(phone_id.encode()).hexdigest() + ".json")
    phone_path.write_text(json.dumps(phone))
    code, refused, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", phone_id)
    check(code != 0 and "phone_capture_provenance_unreadable" in refused["message"] and "Synthetic fixture" not in out + err,
          "unadmitted phone journal never becomes glasses or transcript evidence")
    registry_path.write_text(json.dumps(phone["captureSource"]))
    policy_path.write_text(json.dumps({"sessionId": phone_id, "mode": "anonymous"}))
    code, admitted, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", phone_id)
    check(code == 0 and admitted["details"]["read"]["sourceType"] == "iphone_microphone" and admitted["details"]["read"]["speakerPolicy"] == "anonymous",
          "admitted phone provenance is retained in live DTO")
    check(admitted["details"]["read"]["turns"][0]["speaker"] == "Ext", "phone is anonymous in Control")
    stamp = admitted["details"]["read"]["stamp"]
    code, same, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", phone_id, "--stamp", stamp)
    check(code == 0 and same["details"]["read"]["unchanged"] is True, "phone retains bounded unchanged fast path")
    policy_path.write_text(json.dumps({"sessionId": phone_id, "mode": "standard"}))
    code, refused, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", phone_id, "--stamp", stamp)
    check(code != 0 and "phone_capture_provenance_unreadable" in refused["message"], "same stamp cannot bypass changed phone policy")
    policy_path.write_text(json.dumps({"sessionId": phone_id, "mode": "anonymous"}))
    phone["chunksIndexed"][0]["c"]["speaker"] = "Forged name"
    phone_path.write_text(json.dumps(phone))
    code, refused, out, err = run("live-transcript", "--data-dir", str(data_dir), "--session", phone_id)
    check(code != 0 and "Forged name" not in out + err, "named phone journal rejected without content leakage")
    phone["chunksIndexed"][0]["c"]["speaker"] = "Ext"; phone_path.write_text(json.dumps(phone))
    registry_path.unlink(); registry_path.symlink_to(phone_path)
    code, refused, _, _ = run("live-transcript", "--data-dir", str(data_dir), "--session", phone_id)
    check(code != 0 and phone_path.exists(), "phone metadata symlink refused; evidence retained")
    registry_path.unlink(); registry_path.write_text(json.dumps(phone["captureSource"]))
    status_answer.update(code=200, body={"sessionId": phone_id, "state": "saved", "sourceType": "iphone_microphone", "speakerPolicy": "anonymous", "provenanceState": "admitted"})
    code, saved, _, _ = run("live-transcript-status", "--session", phone_id)
    check(code == 0 and saved["details"]["sourceType"] == "iphone_microphone", "phone status retains source")
    check(seen_paths[-1].endswith("/status?sourceType=iphone_microphone&speakerPolicy=anonymous"), "phone status query is explicit")
    status_answer["body"]["sourceType"] = "mac_system_audio"
    code, refused, _, _ = run("live-transcript-status", "--session", phone_id)
    check(code != 0, "foreign source status cannot reclassify phone")
    before = len(seen_paths)
    for verb, args in [("meeting-stop-request", []), ("meeting-stranded-save", []), ("meeting-speaker-policy", ["--mode", "standard", "--policy-revision", "unset"]), ("meeting-relabel", ["--from", "Ext", "--to", "A name"]), ("voice-enroll-ext", ["--name", "A name"])]:
        code, refused, _, _ = run(verb, "--session", phone_id, *args)
        check(code != 0 and len(seen_paths) == before, verb + " refuses phone before a server request")
    mac_id = "mac_11111111-1111-4111-8111-111111111111"
    mac_path = sessions / (mac_id + ".json")
    original = {"text": "same original words", "speaker": "Ext", "elapsed": 0}
    acoustic = {"sessionId": mac_id, "sourceType": "mac_system_audio", "speakerIdentityPolicy": "acoustic-v1",
                "speakerRevision": 1, "chunksIndexed": [{"i": 0, "c": original}],
                "speakerProjectedChunksIndexed": [{"i": 0, "c": dict(original, speaker="Voice 1")}], "maxChunkIndex": 0}
    def mac_read(known="0"):
        mac_path.write_text(json.dumps(acoustic))
        return run("live-transcript", "--data-dir", str(data_dir), "--session", mac_id, "--since", "0", "--speaker-revision", known)
    code, answer, _, _ = mac_read()
    revised = answer["details"]["read"]
    check(code == 0 and revised["fullSnapshot"] and revised["speakerRevision"] == 1 and revised["turns"][0]["speaker"] == "Voice 1",
          "revision bypasses settled cursor for a late identity")
    check(revised["turns"][0]["text"] == original["text"] and revised["turns"][0]["elapsedMs"] == 0, "projection preserves original words and time")
    code, answer, _, _ = mac_read("1")
    check(code == 0 and not answer["details"]["read"]["fullSnapshot"] and answer["details"]["read"]["turns"] == [], "same revision retains incremental cursor")
    acoustic["speakerRevision"] = 2; acoustic["speakerProjectedChunksIndexed"] = []
    code, answer, _, _ = mac_read("1")
    check(code == 0 and answer["details"]["read"]["turns"][0]["speaker"] == "Ext", "empty overlay restores originals on next revision")
    for field, value in [("text", "altered"), ("elapsed", 6000), ("speaker", "Invented person")]:
        acoustic["speakerProjectedChunksIndexed"] = [{"i": 0, "c": dict(original, speaker="Voice 1", **({field: value} if field != "speaker" else {}))}]
        if field == "speaker": acoustic["speakerProjectedChunksIndexed"][0]["c"][field] = value
        code, answer, out, err = mac_read("1")
        check(code != 0 and "speaker_projection_invalid" in answer["message"] and "altered" not in out + err, "invalid overlay field refused: " + field)
    acoustic["speakerProjectedChunksIndexed"] = [{"i": 0, "c": dict(original, speaker="Voice 1")}] * 2
    check(mac_read("1")[0] != 0, "duplicate overlay indexes refused")
    acoustic["speakerProjectedChunksIndexed"] = []; acoustic["speakerRevision"] = True
    check(mac_read("1")[0] != 0, "boolean speaker revision refused")
    acoustic["speakerRevision"] = 2; acoustic["chunksIndexed"][0]["c"]["speaker"] = "Confirmed person"
    acoustic["speakerProjectedChunksIndexed"] = [{"i": 0, "c": dict(original, speaker="Voice 1")}]
    check(mac_read("1")[0] != 0, "anonymous overlay cannot overwrite existing named person")
    # Mac-native names use full source-bound replacement; no G2 fixture or enrollment.
    import copy
    original = {"text": "same original words", "speaker": "Voice 7", "elapsed": 0,
                "audioSha256": "a" * 64, "audioDurationMs": 6000, "similarity": 0,
                "segments": [{"text": "same original words", "speaker": "Voice 7", "start": 0, "end": 6}],
                "finalSegments": [{"text": "same original words", "speaker": "Voice 7", "start": 0, "end": 6}],
                "words": [{"word": "same", "speaker": "Voice 7", "start": 0, "end": .4}, {"word": "original", "start": .4, "end": .8}]}
    span = {"rawChunkIndex": 0, "audioSHA256": "a" * 64, "pcmSHA256": "b" * 64, "startSample": 0, "endSample": 96000,
            "identityId": "acoustic_" + "c" * 64, "displayLabel": "Qualified Person", "profileName": "Qualified Person", "evidenceIds": ["receipt_a", "receipt_b"]}
    projected = copy.deepcopy(original); projected["speaker"] = span["displayLabel"]
    projected["segments"][0]["speaker"] = span["displayLabel"]; projected["finalSegments"][0]["speaker"] = span["displayLabel"]; projected["words"][0]["speaker"] = span["displayLabel"]
    native = {"sessionId": mac_id, "sourceType": "mac_system_audio", "speakerIdentityPolicy": "mac-native-v1", "speakerRevision": 5,
              "chunksIndexed": [{"i": 0, "c": original}], "speakerProjectedChunksIndexed": [{"i": 0, "c": projected}], "maxChunkIndex": 0,
              "macSpeakerLive": {"version": 1, "captureId": mac_id, "generation": "generation_a", "revision": 5,
                                 "modelSHA256": "d" * 64, "profileSHA256": "e" * 64, "projections": [span]}}
    acoustic = copy.deepcopy(native)
    code, answer, _, _ = mac_read("4")
    check(code == 0 and answer["details"]["read"]["fullSnapshot"] and answer["details"]["read"]["turns"][0]["speaker"] == "Qualified Person", "source-bound late profile name replaces settled Voice label")
    check(answer["details"]["read"]["turns"][0]["text"] == original["text"], "native projection renders original words")
    check(answer["details"]["read"]["turns"][0]["originalSpeaker"] == "Voice 7", "native read separately retains source label for invalidation")
    acoustic["speakerRevision"] = 6; acoustic["macSpeakerLive"]["revision"] = 6
    acoustic["macSpeakerLive"]["projections"] = []; acoustic["speakerProjectedChunksIndexed"] = copy.deepcopy(acoustic["chunksIndexed"])
    code, answer, _, _ = mac_read("5")
    check(code == 0 and answer["details"]["read"]["turns"][0]["speaker"] == "Voice 7", "revocation replaces name with exact original anonymous label")
    for field, value in [("audioSha256", "f" * 64), ("audioDurationMs", 5000), ("elapsed", 1), ("similarity", .99), ("similarity", False), ("text", "changed private text")]:
        acoustic = copy.deepcopy(native); acoustic["speakerProjectedChunksIndexed"][0]["c"][field] = value
        code, answer, out, err = mac_read("4")
        check(code != 0 and "changed private text" not in out + err, "non-label projection mutation refused: " + field)
    for surface in [None, "segments", "finalSegments", "words"]:
        for marker, value in [("speakerOrigin", "manual"), ("manuallyCorrected", True)]:
            acoustic = copy.deepcopy(native)
            for key in ["chunksIndexed", "speakerProjectedChunksIndexed"]:
                target = acoustic[key][0]["c"] if surface is None else acoustic[key][0]["c"][surface][0]
                target[marker] = value
            check(mac_read("4")[0] != 0, "native overwrite refuses human marker on " + str(surface))
    for surface in [None, "segments", "finalSegments", "words"]:
        acoustic = copy.deepcopy(native)
        target = acoustic["chunksIndexed"][0]["c"] if surface is None else acoustic["chunksIndexed"][0]["c"][surface][0]
        target["speaker"] = "Existing Person"
        check(mac_read("4")[0] != 0, "native overwrite refuses existing name on " + str(surface))
    for field, value in [("captureId", "mac_22222222-2222-4222-8222-222222222222"), ("revision", 4), ("modelSHA256", "bad")]:
        acoustic = copy.deepcopy(native); acoustic["macSpeakerLive"][field] = value
        check(mac_read("4")[0] != 0, "native state binding refused: " + field)
    for field, value in [("audioSHA256", "f" * 64), ("startSample", 1), ("endSample", 96001), ("evidenceIds", ["one"]), ("profileName", "Different Person")]:
        acoustic = copy.deepcopy(native); acoustic["macSpeakerLive"]["projections"][0][field] = value
        check(mac_read("4")[0] != 0, "native receipt source binding refused: " + field)
    for field, value in [("audioSha256", "f" * 64), ("audioDurationMs", 5000), ("elapsed", 1)]:
        acoustic = copy.deepcopy(native)
        for key in ["chunksIndexed", "speakerProjectedChunksIndexed"]: acoustic[key][0]["c"][field] = value
        check(mac_read("4")[0] != 0, "current original drift withdraws source-bound native claim: " + field)
    acoustic = copy.deepcopy(native)
    named_original = dict(original, speaker="Existing Person", manuallyCorrected=True)
    acoustic["chunksIndexed"].append({"i": 1, "c": named_original})
    acoustic["speakerProjectedChunksIndexed"].append({"i": 1, "c": copy.deepcopy(named_original)})
    check(mac_read("4")[0] == 0, "unmodified existing manual name survives full overlay")
    acoustic = copy.deepcopy(native)
    del acoustic["macSpeakerLive"]["projections"][0]["profileName"]
    acoustic["macSpeakerLive"]["projections"][0]["displayLabel"] = "Voice 31"
    row = acoustic["speakerProjectedChunksIndexed"][0]["c"]; row["speaker"] = "Voice 31"
    for key in ["segments", "finalSegments", "words"]:
        for word in row[key]:
            if "speaker" in word: word["speaker"] = "Voice 31"
    check(mac_read("4")[0] == 0, "new stable anonymous identity uses backend-allocated display label")
    # An unsupported old Voice31 cannot be merged merely because its hint matches.
    old_voice = dict(original, speaker="Voice 31", elapsed=6000)
    acoustic["chunksIndexed"].append({"i": 1, "c": old_voice})
    acoustic["speakerProjectedChunksIndexed"].append({"i": 1, "c": copy.deepcopy(old_voice)})
    check(mac_read("4")[0] != 0, "new identity cannot collide with unsupported original Voice label")
    acoustic = copy.deepcopy(native); acoustic["speakerProjectedChunksIndexed"] = []
    check(mac_read("4")[0] != 0, "native overlay must cover full original index set")
    acoustic = copy.deepcopy(native); acoustic["chunksIndexed"] *= 2
    check(mac_read("4")[0] != 0, "duplicate original indices refused")
    acoustic = copy.deepcopy(native); acoustic["speakerProjectedChunksIndexed"][0]["c"]["words"][1]["speaker"] = "Qualified Person"
    check(mac_read("4")[0] != 0, "unlabeled ASR word remains unlabeled")
    print("live-transcript helper checks: %d passed" % passed)
finally:
    server.shutdown()
    shutil.rmtree(work, ignore_errors=True)
