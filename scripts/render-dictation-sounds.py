#!/usr/bin/env python3
"""Render COS dictation start/stop sounds offline (0.5.312).

A deterministic port of the Web Audio synthesis Miles approved on 2026-10-15 (design/dictation-sounds-preview.html:
functions v2() "Unstable saber", unstable() "Unstable saber (bright)", cine(), saber(), blips(), chime()). Original synthesis only: oscillators, filters, a tanh
waveshaper and seeded noise. Python standard library only; fixed RNG seed; 44.1 kHz mono 16-bit WAV, peak-normalized
to -1 dBFS, with no high-pass anywhere: v2 lives below 120 Hz and its sub-bass is kept. Rendered at 0 semitones and
the preview's 60% volume; pitch is the person's control at playback (AVAudioUnitTimePitch), never baked into the files.

Usage: python3 scripts/render-dictation-sounds.py [out_dir]   (default Resources/Sounds)
"""
import math, os, random, struct, sys, wave

SR = 44_100
PITCH_SEMITONES = 0
LEVEL = 0.6
P = 2 ** (PITCH_SEMITONES / 12)


class Param:
    """An AudioParam: setValueAtTime and exponentialRampToValueAtTime, evaluated per sample like Web Audio."""
    def __init__(self, value):
        self.default, self.events = value, []
    def set(self, value, at):
        self.events.append(("set", at, value)); return self
    def exp(self, value, at):
        self.events.append(("exp", at, value)); return self
    def lin(self, value, at):
        self.events.append(("lin", at, value)); return self
    def curve(self, n):
        out = [0.0] * n
        segments, t_prev, v_prev = [], 0.0, self.default
        for kind, at, value in self.events:
            segments.append((kind, t_prev, at, v_prev, value))
            t_prev, v_prev = at, value
        i = 0
        for kind, t0, t1, v0, v1 in segments:
            end = min(n, int(math.ceil(t1 * SR)))
            while i < end:
                t = i / SR
                if kind == "exp" and t1 > t0:
                    out[i] = v0 * (v1 / v0) ** ((t - t0) / (t1 - t0))
                elif kind == "lin" and t1 > t0:
                    out[i] = v0 + (v1 - v0) * (t - t0) / (t1 - t0)
                else:
                    out[i] = v0
                i += 1
        while i < n:
            out[i] = v_prev
            i += 1
        return out


def poly_blep(t, dt):
    if t < dt:
        t /= dt; return t + t - t * t - 1.0
    if t > 1.0 - dt:
        t = (t - 1.0) / dt; return t * t + t + t + 1.0
    return 0.0


def oscillator(n, kind, freq, start=0.0, stop=None, lfo=None):
    """`freq` is a per-sample list; `lfo` = (type, rate, depth) added to the frequency. Silent outside [start, stop)."""
    out = [0.0] * n
    phase, lfo_phase = 0.0, 0.0
    first = int(start * SR)
    last = n if stop is None else min(n, int(stop * SR))
    for i in range(first, last):
        f = freq[i]
        if lfo:
            ltype, rate, depth = lfo
            lv = math.sin(2 * math.pi * lfo_phase) if ltype == "sine" else (4 * abs(lfo_phase - 0.5) - 1) * -1
            f += depth * lv
            lfo_phase = (lfo_phase + rate / SR) % 1.0
        dt = max(1e-9, abs(f) / SR)
        if kind == "sine":
            v = math.sin(2 * math.pi * phase)
        elif kind == "sawtooth":
            v = 2.0 * phase - 1.0 - poly_blep(phase, dt)
        elif kind == "square":
            v = (1.0 if phase < 0.5 else -1.0) + poly_blep(phase, dt) - poly_blep((phase + 0.5) % 1.0, dt)
        else:
            v = 4 * abs(phase - 0.5) - 1
        out[i] = v
        phase = (phase + f / SR) % 1.0
    return out


def biquad(signal, kind, freq, q=1.0):
    """Web Audio BiquadFilterNode: lowpass/highpass take Q in dB; bandpass takes Q. `freq` is per sample."""
    out = [0.0] * len(signal)
    x1 = x2 = y1 = y2 = 0.0
    for i, x in enumerate(signal):
        f = min(max(freq[i], 10.0), SR / 2 * 0.999)
        w0 = 2 * math.pi * f / SR
        cw, sw = math.cos(w0), math.sin(w0)
        if kind == "bandpass":
            alpha = sw / (2 * q)
            b0, b1, b2 = alpha, 0.0, -alpha
        else:
            alpha = sw / (2 * 10 ** (q / 20))
            if kind == "lowpass":
                b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
            else:
                b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
        a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
        y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x, y1, y
        out[i] = y
    return out


def shaper(signal, amount):
    return [math.tanh(amount * max(-1.0, min(1.0, x))) for x in signal]


def compressor(signal):
    """DynamicsCompressorNode defaults: threshold -24 dB, knee 30, ratio 12, attack 3 ms, release 250 ms."""
    threshold, knee, ratio = -24.0, 30.0, 12.0
    attack, release = math.exp(-1 / (0.003 * SR)), math.exp(-1 / (0.25 * SR))
    reduction, out = 0.0, []
    for x in signal:
        level = 20 * math.log10(max(abs(x), 1e-9))
        if level < threshold - knee / 2:
            target = level
        elif level > threshold + knee / 2:
            target = threshold + (level - threshold) / ratio
        else:
            target = level + (1 / ratio - 1) * (level - threshold + knee / 2) ** 2 / (2 * knee)
        wanted = target - level
        coefficient = attack if wanted < reduction else release
        reduction = coefficient * reduction + (1 - coefficient) * wanted
        out.append(x * 10 ** (reduction / 20))
    return out


def mul(a, b):
    return [x * y for x, y in zip(a, b)]


def add(a, b, gain=1.0):
    return [x + y * gain for x, y in zip(a, b)]


def play_buffer(n, data, start=0.0, rate=1.0):
    """AudioBufferSourceNode with playbackRate: linear interpolation."""
    out = [0.0] * n
    first = int(start * SR)
    for i in range(first, n):
        pos = (i - first) * rate
        j = int(pos)
        if j + 1 >= len(data):
            break
        frac = pos - j
        out[i] = data[j] * (1 - frac) + data[j + 1] * frac
    return out


def length_for(*seconds):
    return int(math.ceil((max(seconds) + 0.1) * SR))


def saber(rng, up, soft):
    dur = 0.62 if up else 0.38
    n = length_for(dur + 0.05, 0.12 / P)
    env = Param(1.0)
    if up:
        env.set(0.0001, 0).exp(1, 0.07).set(1, 0.25).exp(0.0001, dur)
    else:
        env.set(0.9, 0).exp(0.0001, dur)
    cutoff = Param(350.0).set(300 if up else 2400, 0).exp((1600 if soft else 3200) if up else 200, 0.18 if up else dur)
    base = (82 if soft else 92) * P
    voices = [0.0] * n
    for f, kind, g in [(base, "sawtooth", 0.55), (base * 1.5, "sawtooth", 0.25), (base * 2.01, "square", 0.05 if soft else 0.12)]:
        freq = Param(f).set(f * 0.55 if up else f, 0).exp(f if up else f * 0.45, 0.16 if up else dur).curve(n)
        voices = add(voices, oscillator(n, kind, freq, stop=dur + 0.05, lfo=("sine", 7, f * 0.012)), g)
    signal = mul(biquad(voices, "lowpass", cutoff.curve(n), 0.7 if soft else 4), env.curve(n))
    if not soft and up:
        m = int(SR * 0.12)
        noise = [(rng.random() * 2 - 1) * (1 - i / m) ** 2 for i in range(m)]
        crackle = biquad(play_buffer(n, noise, rate=P), "highpass", [2500.0] * n, 1.0)
        signal = add(signal, crackle, 0.18)
    return signal, (0.5 if soft else 0.9)


def blips(freqs, gap, kind, gain):
    n = length_for(len(freqs) * gap)
    signal = [0.0] * n
    for i, f in enumerate(freqs):
        start = i * gap
        g = Param(1.0).set(0.0001, start).exp(0.8, start + 0.012).exp(0.0001, start + gap * 0.9)
        signal = add(signal, mul(oscillator(n, kind, [f * P] * n, start=start, stop=start + gap), g.curve(n)))
    return signal, gain


def chime(up):
    notes = [f * P for f in ([659.25, 987.77] if up else [987.77, 659.25])]
    n = length_for(0.11 + 0.5)
    signal = [0.0] * n
    for i, f in enumerate(notes):
        for j, h in enumerate([1, 2.01]):
            s = i * 0.11
            g = Param(1.0).set(0.0001, s).exp(0.12 if j else 0.6, s + 0.01).exp(0.0001, s + 0.45)
            signal = add(signal, mul(oscillator(n, "sine", [f * h] * n, start=s, stop=s + 0.5), g.curve(n)))
    return signal, 0.7


def cine(rng, up):
    dur = 1.15 if up else 0.9
    length = 0.42 if up else 0.5
    n = length_for(dur + 0.05, length / P)
    bus = Param(1.0)
    if up:
        bus.set(0.0001, 0).exp(0.9, 0.05).set(0.9, 0.55).exp(0.0001, dur)
    else:
        bus.set(0.85, 0).set(0.85, 0.12).exp(0.0001, dur)
    tone = Param(350.0).set((600 if up else 3800) * P, 0).exp((3800 if up else 300) * P, 0.22 if up else dur * 0.85)
    base = 88 * P
    voices = [0.0] * n
    for k, (f, g) in enumerate([(base, 0.5), (base * 1.007, 0.45), (base * 2.003, 0.22), (base * 3.01, 0.08)]):
        freq = Param(f)
        if up:
            freq.set(f * 2.6, 0).exp(f * 0.86, 0.16).exp(f, 0.32)
        else:
            freq.set(f, 0).set(f * 1.04, 0.08).exp(f * 0.32, dur)
        voices = add(voices, oscillator(n, "square" if k == 3 else "sawtooth", freq.curve(n), stop=dur + 0.05, lfo=("sine", 6.3 + k * 0.4, f * 0.018)), g)
    signal = biquad(shaper(mul(voices, bus.curve(n)), 3.2), "lowpass", tone.curve(n), 1.2)
    m = int(math.ceil(SR * length))
    noise = [(rng.random() * 2 - 1) * ((1 - i / m) ** 1.6 if up else math.sin(math.pi * i / m) * (1 - i / m)) for i in range(m)]
    band = Param(350.0).set(5200 if up else 1400, 0).exp(700 if up else 260, length)
    hiss = biquad(play_buffer(n, noise, rate=P), "bandpass", band.curve(n), 1.4)
    return add(signal, hiss, 0.55 if up else 0.3), 1.0


def unstable(rng, up):
    dur = 1.35 if up else 1.0
    n = length_for(dur + 0.05, dur / P, 0.05 + 0.25 / P)
    bus = Param(1.0)
    if up:
        bus.set(0.0001, 0).exp(1, 0.035).set(0.95, 0.7).exp(0.0001, dur)
    else:
        bus.set(0.95, 0)
        for k in range(1, 7):
            bus.set(0.25 if k % 2 else 0.8, k * 0.09)
        bus.exp(0.0001, dur)
    tone = Param(350.0).set((900 if up else 4200) * P, 0).exp((4600 if up else 260) * P, 0.2 if up else dur * 0.9)
    base = 74 * P
    voices = [0.0] * n
    for k, (f, g) in enumerate([(base, 0.5), (base * 1.013, 0.45), (base * 0.995, 0.3), (base * 2.02, 0.25), (base * 3.03, 0.1)]):
        freq = Param(f)
        if up:
            freq.set(f * 3.2, 0).exp(f * 0.8, 0.14).exp(f, 0.3)
        else:
            freq.set(f, 0).exp(f * 0.28, dur)
        voices = add(voices, oscillator(n, "sawtooth", freq.curve(n), stop=dur + 0.05, lfo=("triangle", 9 + k * 1.7, f * 0.035)), g)
    signal = biquad(shaper(mul(voices, bus.curve(n)), 6.5), "lowpass", tone.curve(n), 0.9)
    # crackle: sparse sharp pops through a resonant highpass, denser at ignition
    m = int(math.ceil(SR * dur))
    data, hold, amp = [0.0] * m, 0.0, 0.0
    for i in range(m):
        k = i / m
        if hold <= 0:
            dense = (0.02 if k < 0.25 else 0.004) if up else 0.006
            if rng.random() < dense:
                hold, amp = 40 + rng.random() * 400, 0.4 + rng.random() * 0.6
            else:
                amp *= 0.995
        else:
            hold -= 1
        data[i] = (rng.random() * 2 - 1) * amp * ((1.6 if k < 0.08 else 1) if up else (1 - k))
    crackle = biquad(play_buffer(n, data, rate=P), "highpass", [1800.0] * n, 3)
    signal = add(signal, crackle, 0.32)
    if up:  # vent flare: two short side bursts
        for off in (0.0, 0.05):
            v = int(math.ceil(SR * 0.25))
            burst = [(rng.random() * 2 - 1) * (1 - i / v) ** 2.2 for i in range(v)]
            band = Param(350.0).set(6000, off).exp(900, off + 0.25)
            signal = add(signal, biquad(play_buffer(n, burst, start=off, rate=P), "bandpass", band.curve(n), 1.1), 0.5)
    return signal, 1.0


def unstable_v2(rng, up):
    """v2, measured from Miles's reference (2026-10-15): a 47 Hz growl with beating partials, a slow swell and fast
    flutter, pitch wander, sparse spits; ignition drops into the hilt with a bright eject burst; the retract flares and cuts."""
    p = P
    f0, dur = 47 * p, (1.35 if up else 0.34)
    n = length_for(dur + 0.1, 0.05 + 0.26 / p)
    trem = [0.72] * n
    for rate, depth in [(0.65, 0.22), (23, 0.16), (7.3, 0.07)]:
        stop = int(min(n, (dur + 0.1) * SR))
        for i in range(stop):
            trem[i] += depth * math.sin(2 * math.pi * rate * i / SR)
    voices = [0.0] * n
    for m, kind, g in [(1, "sawtooth", 0.55), (1.19, "sawtooth", 0.13), (1.5, "sine", 0.18), (2.03, "sawtooth", 0.33), (3.02, "triangle", 0.08)]:
        f = f0 * m
        freq = Param(f)
        if up:
            freq.set(f * 1.42, 0).exp(f * 0.97, 0.06).exp(f, 0.18)
        else:
            freq.set(f, 0).exp(f * 1.06, 0.28)
        voices = add(voices, oscillator(n, kind, freq.curve(n), stop=dur + 0.05, lfo=("triangle", 2.3 + m, f * 0.045)), g)
    cutoff, bus = Param(350.0), Param(1.0)
    if up:
        cutoff.set(500 * p, 0).exp(1900 * p, 0.09).exp(420 * p, 0.3).set(420 * p, dur)
        bus.set(0.0001, 0).exp(0.85, 0.012).exp(0.7, 0.2).exp(1.0, 0.5).exp(0.42, 1.0).exp(0.0001, dur)
    else:
        cutoff.set(420 * p, 0).exp(700 * p, 0.27)
        bus.set(0.55, 0).exp(1.1, 0.27).set(1.1, 0.3).lin(0.0, 0.315)
    signal = mul(mul(voices, trem), bus.curve(n))
    signal = biquad(biquad(shaper(signal, 2.2), "lowpass", cutoff.curve(n), 0.8), "lowpass", [2600 * p] * n, 1.0)
    if up:  # eject burst: bright band-passed noise 60-250 ms, sweeping down
        m = int(math.ceil(SR * 0.26))
        burst = [(rng.random() * 2 - 1) * ((i / m) / 0.2 if i / m < 0.2 else (1 - (i / m - 0.2) / 0.8) ** 1.5) for i in range(m)]
        band = Param(350.0).set(3400 * p, 0.05).exp(650 * p, 0.3)
        signal = add(signal, biquad(play_buffer(n, burst, start=0.05, rate=p), "bandpass", band.curve(n), 1.0), 0.42)
    # sparse spits: ~1.5/s, short sharp clicks through a highpass, quiet
    m = int(math.ceil(SR * dur))
    spits = [0.0] * m
    next_at = int(SR * (0.15 + rng.random() * 0.3))
    for i in range(m):
        if i == next_at:
            length = 60 + int(rng.random() * 220)
            for j in range(length):
                if i + j < m:
                    spits[i + j] = (rng.random() * 2 - 1) * (1 - j / length) ** 2
            next_at = i + int(SR * (0.35 + rng.random() * 0.6))
    signal = add(signal, biquad(play_buffer(n, spits), "highpass", [2200.0] * n, 1.0), 0.22)
    return signal, 1.25


def master(signal, gain):
    return compressor([x * gain * LEVEL for x in signal])


def write(path, signal):
    peak = max(abs(x) for x in signal) or 1.0
    scale = 10 ** (-1 / 20) / peak
    fade = int(0.005 * SR)
    samples = [x * scale for x in signal]
    for i in range(fade):
        samples[-1 - i] *= i / fade
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(round(x * 32767))))) for x in samples))


SOUNDS = {
    "unstable-saber": (lambda rng: unstable_v2(rng, True), lambda rng: unstable_v2(rng, False)),
    "unstable-saber-bright": (lambda rng: unstable(rng, True), lambda rng: unstable(rng, False)),
    "saber-full": (lambda rng: cine(rng, True), lambda rng: cine(rng, False)),
    "saber-ignite": (lambda rng: saber(rng, True, False), lambda rng: saber(rng, False, False)),
    "saber-soft": (lambda rng: saber(rng, True, True), lambda rng: saber(rng, False, True)),
    "droid-chirp": (lambda rng: blips([1320, 1980], 0.07, "square", 0.25), lambda rng: blips([1980, 1320], 0.07, "square", 0.25)),
    "soft-chime": (lambda rng: chime(True), lambda rng: chime(False)),
}


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")
    os.makedirs(out_dir, exist_ok=True)
    for name, (start, stop) in SOUNDS.items():
        for edge, make in (("start", start), ("stop", stop)):
            rng = random.Random(f"cos-dictation-{name}-{edge}")
            signal, gain = make(rng)
            path = os.path.join(out_dir, f"{name}-{edge}.wav")
            write(path, master(signal, gain))
            print(f"{path}  {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
