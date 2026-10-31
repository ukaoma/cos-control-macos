#!/usr/bin/env python3
"""Control's half of the restart lockout, end to end: a health payload through the compiled helper's `status`, then through
ServerStatus (Tests/MeetingRestartChecks.swift), down to what the disabled buttons read. Then the helper's own scan of
pending-batch for each answer lsof and launchd could give. Temporary home and a private loopback fixture only: never the
live service or ~/.cos-glasses. Prints "meeting restart checks: N passed". Usage: meeting-restart-checks.py <helper> <checks>"""
import json, os, pathlib, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

checks = 0


def check(value, name):
    global checks
    if not value:
        sys.exit(f"Fatal error: {name}")
    checks += 1


subprocess.run([sys.argv[2]], check=True, stdout=subprocess.DEVNULL)
# The exact 6.97.0 payload, from the server's own pin (only the row's updatedAt and lastError may vary).
STOPPED_WORDS = "HQ polish stopped · audio kept · retries later"
STOPPED_ROW = {"meetingId": "meeting_1700000000000_abc", "phase": "stopped", "percent": None, "segmentsDone": None, "segmentsTotal": None, "chunkFiles": 2, "updatedAt": "2026-10-31T17:00:00.000Z", "label": STOPPED_WORDS}
STOPPED_SYNC = {"active": False, "percent": None, "label": STOPPED_WORDS, "blocksRestart": False, "meetings": [STOPPED_ROW], "retained": []}
STOPPED_FINAL = {"pending": 0, "failed": 0, "oldestUpdatedAt": None, "lastError": "decode failed", "malformed": 0}
WORKING = {"meetingId": "meeting_1789761552246_qfcpyr", "phase": "hq_polish", "active": True, "blocksRestart": True, "percent": 62, "chunkFiles": 40, "label": "HQ polish 62% (70/113)"}
with tempfile.TemporaryDirectory(prefix="cos-restart-", dir="/tmp") as tmp:
    home = pathlib.Path(tmp) / "home"; home.mkdir()
    state = {"health": {}}

    class Health(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            if self.path != "/api/health":
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
            raw = json.dumps(state["health"]).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)

    server = HTTPServer(("127.0.0.1", 0), Health)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {"PATH": "/usr/bin:/bin", "COS_CONTROL_TEST_HOME": str(home), "COS_CONTROL_TEST_API_PORT": str(server.server_port), "HOME": str(home), "CFFIXED_USER_HOME": str(home)}

    def through_panel(*helper_args):
        done = subprocess.run([sys.argv[1], *helper_args], capture_output=True, text=True, env=env, timeout=120)
        reply = pathlib.Path(tmp) / "reply.json"
        reply.write_text(done.stdout.strip().splitlines()[-1])
        seen = subprocess.run([sys.argv[2], "check", str(reply)], capture_output=True, text=True, check=True)
        return json.loads(seen.stdout)

    def health(sync, final=None):
        state["health"] = {"server_version": "6.97.0", "meeting_sync": sync, "capabilities": {"meetingLifecycle": {"finalization": final or {"pending": 0, "failed": 0, "malformed": 0}}}}
        return through_panel("status")

    only = health(STOPPED_SYNC, STOPPED_FINAL)
    check(only["blocking"] is False, "the stopped payload leaves Restart and Update Server on")
    check(only["active"] is False and only["blocksFlag"] is False, "the stopped payload leaves Run sync now on")
    check(only["label"] == STOPPED_WORDS and [r["stage"] for r in only["rows"]] == [STOPPED_WORDS] and only["rows"][0]["held"] is True and only["rows"][0]["waiting"] is False, "the stopped row is visible with its label")
    check(only["lastError"] == "decode failed", "a last error with nothing pending reaches the panel and locks nothing")
    check(only["note"] and "Update Server" in only["note"] and "retrying" not in json.dumps(only).lower(), "nothing says retrying, and the note says what still works")
    busy = health({"active": True, "blocksRestart": True, "percent": 62, "label": "HQ polish 62% (70/113)", "meetings": [WORKING]}, {"pending": 1, "failed": 0, "malformed": 0})
    check(busy["blocking"] is True and busy["note"] is None, "a working job stays locked, on a payload with no new fields")
    both = health({"active": True, "blocksRestart": True, "percent": 62, "label": "HQ polish 62% (70/113)", "meetings": [WORKING, STOPPED_ROW], "retained": []})
    check(both["blocking"] is True and both["rows"][0]["held"] is False and both["rows"][1]["held"] is True, "a stopped job beside a working one still blocks")
    saving = health(STOPPED_SYNC, {**STOPPED_FINAL, "pending": 1})
    check(saving["blocking"] is True and "library" in saving["reason"], "a stopped job beside a real save still blocks")
    old = health({"active": False, "percent": None, "label": "Idle", "blocksRestart": False, "meetings": []})
    check(old["blocking"] is False and old["label"] == "Idle" and old["note"] is None, "an old idle payload behaves as before")
    server.shutdown()

    # The scan, with no server to ask. Audio in one folder, and a progress file nothing is writing to.
    batch = home / ".cos-glasses/data/pending-batch"
    (batch / "meeting_1").mkdir(parents=True)
    (batch / "meeting_1/chunk_0001.wav").write_bytes(b"RIFF")
    (batch / "meeting_1/_batch_progress.json").write_text(json.dumps({"segmentsDone": 2, "segmentsTotal": 5}))
    stopped = through_panel("self-test-held-audio")
    check(stopped["blocking"] is False, "stopped, held audio blocks nothing")
    check(stopped["label"] == "Audio kept for 1 meeting" and "HQ polish" not in stopped["label"], "stopped, the row says audio is kept")
    check(stopped["note"] and stopped["note"].startswith("The server is stopped"), "stopped, the note says what still works")
    check((batch / "meeting_1/chunk_0001.wav").exists(), "reading the status deletes nothing")
    silent = through_panel("self-test-held-audio", "--process")
    check(silent["blocking"] is True and "not answering" in silent["label"] and "not answering" in silent["reason"], "a process that does not answer stays blocked and says why")
    older = through_panel("self-test-held-audio", "--process", "--answered")
    check(older["blocking"] is True and older["label"].startswith("HQ polish"), "a running older server keeps its own reading")
    (batch / "meeting_1/chunk_0001.wav").unlink(); (batch / "meeting_1/_batch_progress.json").unlink()
    (batch / "meeting_1/_batch_pending.marker").write_text("")
    empty = through_panel("self-test-held-audio")
    check(empty["blocking"] is False and empty["label"] == "Idle" and empty["note"] is None, "a folder with no audio is not kept audio")
root = pathlib.Path(__file__).resolve().parents[1]
sources = {name: (root / name).read_text() for name in ("HelperSources/main.swift", "Sources/Views.swift", "Sources/ActivityWindow.swift", "Sources/ProviderConnectViews.swift", "Sources/ControllerModel.swift")}
controller = sources["Sources/ControllerModel.swift"]
check("still being saved" not in controller and controller.count("status.meetingFinalizingWords(session: session)") == 6 and controller.count("message = finalizingWords") == 1 and controller.count('case "meeting_finalizing": return finalizingWords') == 1, "every speaker refusal asks which words are true")
views = sources["Sources/Views.swift"]
check("model.voiceSuggestions.line(for: review, saveStopped: model.status.meetingSaveStopped(session: review.sessionId))" in views
      and "model.voiceBatch.result?.line(saveStopped: saveStopped) ?? model.voiceBatch.undoResult?.line(saveStopped: saveStopped)" in views
      and "voiceBatch.result?.line ??" not in views and controller.count(".line(saveStopped: status.meetingSaveStopped(session: session))") == 2,
      "the voice check and batch lines on screen ask which words are true")
check(sources["HelperSources/main.swift"].count("workCanRun: !snapshot.allListenerPIDs.isEmpty || snapshot.servicePID != nil, serverAnswered: false") == 1, "only no listener and no launchd pid counts as stopped")
check(sources["HelperSources/main.swift"].count("guard health == nil else { return meetingSyncStatusFromPendingBatch(workCanRun: true, serverAnswered: true) }") == 1, "a server that answers keeps the scan's reading")
check("Text(model.status.meetingWorkBlockReason)" in sources["Sources/Views.swift"] and "model.status.heldAudioNote" in sources["Sources/Views.swift"], "the panel shows the reason and the note")
for name in ("Sources/Views.swift", "Sources/ActivityWindow.swift", "Sources/ProviderConnectViews.swift"):
    check("model.status.meetingWorkBlockingRestart ? model.status.meetingWorkBlockReason :" in sources[name], f"{name}: a disabled Update Server says why")
print(f"meeting restart checks: {checks} passed")
