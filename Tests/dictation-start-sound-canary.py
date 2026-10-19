#!/usr/bin/env python3
"""0.5.327 start-sound canary, against the REAL local engine. Run by hand (it needs a running COS server with a local
dictation engine); never part of Tests/run.sh, which has no engine.

    python3 Tests/dictation-start-sound-canary.py <compiled cos-control-helper> <evidence dir> [repo root] [extra start .wav ...]

Why. 0.5.327 plays the start sound when the microphone's first buffer arrives, so on speakers the sound is now at the
very start of every recording (before, it usually played while the microphone was still opening). It is still not
trimmed (DictationSoundPlayer explains why). This proves the sound there does not cost words: the pinned voice sample
(Resources/VoiceBenchmark/speech-30s.wav, first utterance) goes through the helper's real dictation route (mac-dictation,
Parakeet Ultra or Whisper by the server's setting) clean, then with each bundled start sound (and any extra file named)
mixed in at its front, at the default volume (0.6) and at full volume, the speech starting as the sound ends (the person
waits for the cue). Worst case, mixed straight in with no room loss; a microphone hears less.

A positive control first: the clean sample must keep its first and last words. PASS when every sound case hears the same
first word as the clean control, no extra leading word, and at least the control's matched words minus one. The case of
someone already talking over the sound is reported, not judged. Read-only on this Mac but for the evidence directory;
the evidence keeps word counts and the first and last word of a public-domain sample, never a person's dictation.
"""
import json, pathlib, re, struct, subprocess, sys

helper, evidence = sys.argv[1], pathlib.Path(sys.argv[2])
root = pathlib.Path(sys.argv[3] if len(sys.argv) > 3 else pathlib.Path(__file__).resolve().parent.parent)
extra = [pathlib.Path(p) for p in sys.argv[4:]]
evidence.mkdir(parents=True, exist_ok=True)
RATE = 16_000


def read_wav(path):
    data = path.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", f"{path.name}: not a WAV"
    i, fmt, pcm = 12, None, None
    while i + 8 <= len(data):
        cid, n = data[i:i + 4], struct.unpack("<I", data[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", data[i + 8:i + 24])
        elif cid == b"data":
            pcm = data[i + 8:i + 8 + n]
            break
        i += 8 + n + (n & 1)
    assert fmt and pcm is not None and fmt[0] == 1 and fmt[5] == 16, f"{path.name}: PCM16 only"
    channels, rate = fmt[1], fmt[2]
    samples = struct.unpack(f"<{len(pcm) // 2}h", pcm[: len(pcm) // 2 * 2])
    mono = [sum(samples[j:j + channels]) / channels for j in range(0, len(samples) - channels + 1, channels)]
    if rate == RATE:
        return mono
    out, step = [], rate / RATE  # linear resample to 16 kHz
    for k in range(int(len(mono) / step)):
        x = k * step; j = int(x); f = x - j
        out.append(mono[j] * (1 - f) + mono[min(j + 1, len(mono) - 1)] * f)
    return out


def wav(samples):
    body = struct.pack(f"<{len(samples)}h", *[max(-32768, min(32767, int(round(s)))) for s in samples])
    return b"RIFF" + struct.pack("<I", len(body) + 36) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16) \
        + b"data" + struct.pack("<I", len(body)) + body


speech = read_wav(root / "Resources/VoiceBenchmark/speech-30s.wav")[: 11 * RATE]  # the first copy (DictationCheckSample.seconds)
reference = re.findall(r"[a-z']+", (root / "Resources/VoiceBenchmark/speech-30s.txt").read_text().lower())[:22]
assert reference[-1] == "country" and len(reference) == 22, "the first copy ends on 'country'"


def dictate(samples):
    proc = subprocess.run([helper, "mac-dictation"], input=wav(samples), capture_output=True, timeout=60)
    result = json.loads(proc.stdout or b"{}")
    return result.get("ok"), result.get("details", {}).get("engine"), re.findall(r"[a-z']+", (result.get("details", {}).get("text") or "").lower())


def matched(heard):
    """Longest common subsequence with the reference: words heard in order."""
    prev = [0] * (len(heard) + 1)
    for r in reference:
        cur = [0]
        for j, h in enumerate(heard):
            cur.append(prev[j] + 1 if r == h else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]


def leading_extra(heard):
    return next((i for i, h in enumerate(heard) if h == reference[0]), len(heard))


ok, engine, heard = dictate(speech)
control = {"case": "clean", "ok": ok, "engine": engine, "words": len(heard), "matched": matched(heard),
           "first": heard[0] if heard else None, "last": heard[-1] if heard else None, "leadingExtra": leading_extra(heard)}
print(f"  control: {control['matched']}/{len(reference)} words in order, first '{control['first']}', last '{control['last']}' ({engine})")
if not (ok and control["first"] == reference[0] and control["last"] == "country"):
    (evidence / "start-sound-canary.json").write_text(json.dumps({"verdict": "FAIL", "control": control}, indent=2) + "\n")
    sys.exit("FAIL start-sound canary: the clean control lost its first or last word, so it proves nothing")

sounds = sorted((root / "Resources/Sounds").glob("*-start.wav")) + extra
runs, failures = [], []
for path in sounds:
    tone = read_wav(path)
    for volume in (0.6, 1.0):
        for overlap in (False, True):
            if overlap:  # talking over the sound: speech from the first sample
                mixed = [s + (tone[i] * volume if i < len(tone) else 0) for i, s in enumerate(speech)]
            else:        # the sound, then the speech as it ends
                mixed = [t * volume for t in tone] + list(speech)
            ok, engine, words = dictate(mixed)
            row = {"sound": path.name if path.parent.name == "Sounds" else "extra:" + path.name, "volume": volume, "overlap": overlap,
                   "soundMs": round(len(tone) / RATE * 1000), "ok": ok, "engine": engine, "words": len(words), "matched": matched(words),
                   "first": words[0] if words else None, "leadingExtra": leading_extra(words)}
            judged = not overlap
            passed = bool(ok) and row["first"] == control["first"] and row["leadingExtra"] == 0 and row["matched"] >= control["matched"] - 1
            row["judged"], row["passed"] = judged, passed
            runs.append(row)
            if judged and not passed:
                failures.append(f"{row['sound']} at {volume}")
            print(f"  {'ok  ' if passed else ('LOST' if judged else 'info')} {row['sound']} vol {volume} {'over speech' if overlap else 'then speech'}: "
                  f"{row['matched']}/{len(reference)}, first '{row['first']}', {row['leadingExtra']} extra leading")

verdict = "FAIL" if failures else "PASS"
(evidence / "start-sound-canary.json").write_text(json.dumps({"verdict": verdict, "control": control, "runs": runs,
    "note": "Word counts and first words of a public-domain sample only; no dictation of a person."}, indent=2) + "\n")
judged = sum(1 for r in runs if r["judged"])
print(f"{verdict} start-sound canary: {judged - len(failures)} of {judged} sound-then-speech cases hear the same first word, nothing extra before it, and within one word of the clean control"
      + (f"; lost words with {', '.join(failures)}" if failures else "") + f"; evidence {evidence / 'start-sound-canary.json'}")
sys.exit(0 if verdict == "PASS" else 1)
