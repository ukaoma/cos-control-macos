#!/usr/bin/env python3
"""0.5.326 release-tail canary, against the REAL local engine. Run by hand (it needs a running COS server with a local
dictation engine); never part of Tests/run.sh, which has no engine.

    python3 Tests/dictation-tail-canary.py <compiled cos-control-helper> <evidence dir> [repo root]

What it proves. The pinned voice sample (Resources/VoiceBenchmark/speech-30s.wav, the same clip dictation-check uses)
ends its first utterance on "...for your country". The canary finds where that last word ends in the audio, models a
release there and 120 ms before it (a person lets go while finishing the word, and the device and tap still hold about
that much audio in flight), and sends each capture through the helper's real dictation route (mac-dictation, the path a
dictation takes, Parakeet Ultra or Whisper by the server's setting) to the real engine:

  without the tail (0.5.325): the capture ends at the release, minus the in-flight audio that was dropped;
  with the tail (0.5.326):    the capture runs DictationReleaseTail.milliseconds past the release (read from the source).

A positive control first: the full utterance must transcribe with its last word, or the run proves nothing. The canary
FAILS unless at least one no-tail capture loses the last word (otherwise it cannot discriminate) and every tail capture
keeps it. Read-only on this Mac: the helper reads the pairing token; nothing is written but the evidence directory.
"""
import json, math, pathlib, re, struct, subprocess, sys, time

helper, evidence = sys.argv[1], pathlib.Path(sys.argv[2])
root = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else pathlib.Path(__file__).resolve().parent.parent)
evidence.mkdir(parents=True, exist_ok=True)
RATE = 16_000
INFLIGHT_MS = 120
tail_ms = int(re.search(r"static let milliseconds = (\d+)", (root / "Sources/MacDictationCore.swift").read_text()).group(1))

wav = (root / "Resources/VoiceBenchmark/speech-30s.wav").read_bytes()
assert wav[:4] == b"RIFF" and wav[8:12] == b"WAVE" and wav[36:40] == b"data", "pinned sample layout"
channels, rate, bits = struct.unpack("<H", wav[22:24])[0], struct.unpack("<I", wav[24:28])[0], struct.unpack("<H", wav[34:36])[0]
assert (channels, rate, bits) == (1, RATE, 16), "16 kHz mono PCM16"
pcm = wav[44:]
utterance = pcm[: 11 * RATE * 2]  # the first copy (DictationCheckSample.seconds)
reference = (root / "Resources/VoiceBenchmark/speech-30s.txt").read_text()
words = re.findall(r"[a-z']+", reference.lower())[:22]
assert words[-1] == "country" and len(words) == 22, "the first copy ends on 'country'"


def rms_db(chunk):
    n = len(chunk) // 2
    if n == 0:
        return -120.0
    total = sum(s * s for s in struct.unpack(f"<{n}h", chunk[: n * 2]))
    rms = math.sqrt(total / n) / 32768
    return 20 * math.log10(rms) if rms > 0 else -120.0


frame = RATE * 2 // 50  # 20 ms
levels = [rms_db(utterance[i:i + frame]) for i in range(0, len(utterance), frame)]
peak = max(levels)
# The clip has crowd noise after the last word, rising to about 24 dB under the peak before the next copy. Speech is the
# frames within 15 dB of the peak; the last of them ends "country" (measured: 10,180 ms, the "-try" at 10,080 to 10,160).
speech = [i for i, level in enumerate(levels) if level > peak - 15]
end_ms = (speech[-1] + 1) * 20
assert 9_800 <= end_ms <= 10_400, f"the last word's end moved ({end_ms} ms): re-measure before trusting this canary"


def capture(release_ms, tail):
    """The PCM a dictation holds for a release at `release_ms`: 0.5.325 drops the in-flight audio; the tail runs past it."""
    stop_ms = release_ms + tail_ms if tail else release_ms - INFLIGHT_MS
    stop = max(0, min(len(utterance), stop_ms * 32)) // 2 * 2
    body = utterance[:stop]
    return b"RIFF" + struct.pack("<I", len(body) + 36) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16) \
        + b"data" + struct.pack("<I", len(body)) + body, stop / 32


def dictate(audio):
    started = time.monotonic()
    proc = subprocess.run([helper, "mac-dictation"], input=audio, capture_output=True, timeout=60)
    result = json.loads(proc.stdout or b"{}")
    return result, round((time.monotonic() - started) * 1000)


def score(text):
    heard = re.findall(r"[a-z']+", (text or "").lower())
    return {"lastWordKept": bool(heard) and heard[-1] == "country", "words": len(heard),
            "tailWords": " ".join(heard[-4:])}


runs = []
control_audio, control_ms = capture(len(utterance) // 32 + INFLIGHT_MS, tail=False)
control, ms = dictate(control_audio)
runs.append({"case": "positive control: the whole utterance", "captureMs": round(control_ms), "ok": control.get("ok"),
             "engine": control.get("details", {}).get("engine"), "elapsedMs": ms, **score(control.get("details", {}).get("text"))})
for release_offset in (0, -INFLIGHT_MS):
    for tail in (False, True):
        audio, kept_ms = capture(end_ms + release_offset, tail)
        result, ms = dictate(audio)
        runs.append({"case": f"release {'at' if release_offset == 0 else f'{-release_offset} ms before'} the end of the last word, "
                             + (f"with the {tail_ms} ms tail" if tail else "without a tail (0.5.325)"),
                     "tail": tail, "releaseMs": end_ms + release_offset, "captureMs": round(kept_ms), "ok": result.get("ok"),
                     "engine": result.get("details", {}).get("engine"), "elapsedMs": ms,
                     **score(result.get("details", {}).get("text"))})

control_ok = runs[0]["ok"] and runs[0]["lastWordKept"]
no_tail_lost = any(r.get("tail") is False and not r["lastWordKept"] for r in runs[1:])
tail_kept = all(r["ok"] and r["lastWordKept"] for r in runs[1:] if r.get("tail"))
verdict = "PASS" if control_ok and no_tail_lost and tail_kept else "FAIL"
report = {"verdict": verdict, "tailMs": tail_ms, "inflightMs": INFLIGHT_MS, "lastWordEndMs": end_ms,
          "checks": {"positiveControlKeepsLastWord": control_ok, "someNoTailCaptureLosesLastWord": no_tail_lost,
                     "everyTailCaptureKeepsLastWord": tail_kept},
          "runs": runs, "note": "Text is kept only as the last four words of a public-domain sample; no dictation of a person."}
(evidence / "tail-canary.json").write_text(json.dumps(report, indent=2) + "\n")
for r in runs:
    print(f"  {'kept' if r['lastWordKept'] else 'LOST'}  {r['case']}: capture {r['captureMs']} ms, '{r['tailWords']}' ({r['engine']}, {r['elapsedMs']} ms)")
print(f"{verdict} release-tail canary: control {'ok' if control_ok else 'BROKEN'}, without the tail the last word "
      f"{'is lost' if no_tail_lost else 'SURVIVES (the canary cannot discriminate)'}, with the tail "
      f"{'it is kept' if tail_kept else 'it is STILL LOST'}; evidence {evidence / 'tail-canary.json'}")
sys.exit(0 if verdict == "PASS" else 1)
