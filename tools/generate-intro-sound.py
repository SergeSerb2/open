#!/usr/bin/env python3
"""Synthesize Open Intro. Original score, fixed seed, stdlib DSP; never plays audio.

PCM is the reproducible source of truth. AAC encoders may differ by OS version.
--check regenerates PCM and compares the committed AAC's decoded half-second
curve, duration and silent tail. The largest allocation is a 960000-float array
(3,840,000 bytes); no reference audio or third-party DSP code is used.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import tempfile
import time
import wave

RATE = 48000
TIMELINE = Path(__file__).resolve().parents[1] / "Packages/OpenKit/Sources/OpenOnboarding/IntroTimeline.swift"
BEATS = {name: (float(a), float(b)) for name, a, b in re.findall(r'.init\(name: "([^"]+)", start: ([0-9.]+), end: ([0-9.]+)\)', TIMELINE.read_text())}
DURATION = int(BEATS["sound"][1])
FADE_START, SILENCE_START = BEATS["soundFade"]
SEED = 0x4F50454E17
EXPECTED_PCM = "980936f5cb2cf2d3488e6ff160e57dabf5ef27e55902d3aa23481936d21859b5"
DEST = Path(__file__).resolve().parents[1] / "Packages/OpenKit/Sources/OpenOnboarding/Resources/Onboarding/open-intro.m4a"
TAU = math.tau
TABLE_SIZE = 16384


def hz(midi):
    return 440 * 2 ** ((midi - 69) / 12)


def smooth(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def synthesize():
    count = RATE * DURATION
    left, right = array('f', [0]) * count, array('f', [0]) * count
    table = [sum(math.sin(TAU * n * i / TABLE_SIZE) / n ** 1.6 for n in range(1, 9))
             for i in range(TABLE_SIZE)]
    table.append(table[0])
    # MIDI notes exactly describe the lead's D-major progression. The final
    # suspended chord resolves halfway through the last 3.5-second phrase.
    chords = [(0, 16/3, [38, 45, 54, 61, 64]),
              (16/3, 32/3, [35, 42, 50, 57, 64]),
              (32/3, 16, [31, 50, 54, 57, 61]),
              (16, 17.75, [33, 52, 59, 66]),
              (17.75, SILENCE_START, [38, 45, 52, 54])]
    for start, end, notes in chords:
        a, b = max(0, round((start - .45) * RATE)), min(count, round((end + .45) * RATE))
        for ni, note in enumerate(notes):
            pan = -.4 + .8 * ni / (len(notes) - 1)
            lg, rg = math.sqrt((1 - pan) / 2), math.sqrt((1 + pan) / 2)
            for cents in (-5, 0, 5):
                phase = 0.0
                step = hz(note) * 2 ** (cents / 1200) * TABLE_SIZE / RATE
                for i in range(a, b):
                    t = i / RATE
                    env = smooth((t - (start - .45)) / .9) if start else 1.0
                    env *= 1 - smooth((t - (end - .45)) / .9)
                    # ±2-cent, .18-Hz slow vibrato; wavetable supplies harmonics 1–8.
                    phase = (phase + step * 2 ** (2 * math.sin(TAU * .18 * t) / 1200)) % TABLE_SIZE
                    p = int(phase)
                    value = (table[p] + (table[p + 1] - table[p]) * (phase - p)) * env / (len(notes) * 3)
                    left[i] += value * lg
                    right[i] += value * rg
        # Chord root one octave below the pad, -20 dB relative, 2 s entry.
        root = hz(notes[0] - 12)
        for i in range(max(a, round(BEATS["subEntry"][0] * RATE)), b):
            t = i / RATE
            env = smooth((t - BEATS["subEntry"][0]) / (BEATS["subEntry"][1]-BEATS["subEntry"][0]))
            if start: env *= smooth((t - (start - .45)) / .9)
            env *= 1 - smooth((t - (end - .45)) / .9)
            value = .1 * env * math.sin(TAU * root * t)
            left[i] += value * .70710678
            right[i] += value * .70710678

    bells_l, bells_r = array('f', [0]) * count, array('f', [0]) * count
    bells = [(BEATS["door"][1], 69, .55), (BEATS["bellPair"][0], 74, .5), (BEATS["bellPair"][1], 78, .5), (BEATS["plateau"][0], 81, 1.1)]
    # Plateau bars at 90 BPM: beats 1, 1.5, 2.5, 3; 4/4 bar = 8/3 s.
    bar = BEATS["plateau"][0]
    while bar < FADE_START:
        bells += [(bar + beat * 2/3, note, .35) for beat, note in zip((0, .5, 1.5, 2), (74, 76, 78, 81))
                  if bar + beat * 2/3 < FADE_START]
        bar += 8/3
    for bi, (onset, midi, velocity) in enumerate(bells):
        f = hz(midi)
        for i in range(round(onset * RATE), min(count, round((onset + 7) * RATE))):
            t = i / RATE - onset
            value = velocity * min(t / .008, 1) * math.exp(-t / 1.4) * math.sin(TAU * f * t + 2.2 * math.exp(-t / .35) * math.sin(TAU * 3.5 * f * t))
            bells_l[i] += value * (.8 if bi % 2 == 0 else .4)
            bells_r[i] += value * (.4 if bi % 2 == 0 else .8)
    delay = RATE // 2
    # Delay state is only delayed material: each bounce crosses the stereo field.
    dl, dr = array('f', [0]) * count, array('f', [0]) * count
    for i in range(count):
        if i >= delay:
            dl[i] = bells_r[i-delay] + .32 * dr[i-delay]
            dr[i] = bells_l[i-delay] + .32 * dl[i-delay]
        left[i] += bells_l[i] * .18 + dl[i] * .18 * .3
        right[i] += bells_r[i] * .18 + dr[i] * .18 * .3

    rng = random.Random(SEED)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(round(BEATS["airSweep"][0] * RATE), round(BEATS["soundFade"][1] * RATE)):
        t = i / RATE
        sweep = min(1, (t - BEATS["airSweep"][0]) / (BEATS["airSweep"][1]-BEATS["airSweep"][0]))
        omega = TAU * (2000 + 6000 * sweep) / RATE
        alpha = math.sin(omega) / 2  # two-pole constant-skirt band-pass, Q=1
        norm = 1 / (1 + alpha)
        x = rng.uniform(-1, 1)
        y = alpha * norm * (x - x2) + 2 * math.cos(omega) * norm * y1 - (1-alpha) * norm * y2
        x2, x1, y2, y1 = x1, x, y1, y
        level = 10 ** ((-24 - 12 * min(1, max(0, (t-BEATS["airSweep"][1])/3))) / 20)
        value = y * level * smooth((t-BEATS["airSweep"][0])/.3)
        left[i] += value * .70710678
        right[i] += value * .70710678

    # Original Freeverb-style network: 8 parallel combs, 4 serial allpasses.
    # Delay lengths are primes near 25–37 ms (comb) and 5–12 ms (allpass).
    for channel, spread in ((left, 0), (right, 37)):
        wet = array('f', [0]) * count
        feedback = .7 + .82 * .28
        for length in (1213, 1291, 1381, 1459, 1543, 1619, 1699, 1789):
            length += spread
            buf = array('f', [0]) * length
            pos, low = 0, 0.0
            for i, value in enumerate(channel):
                out = buf[pos]
                low = out * (1-.35) + low * .35
                buf[pos] = value * .18 + low * feedback
                wet[i] += out / 8
                pos += 1
                if pos == length: pos = 0
        for length in (563, 443, 337, 241):
            length += spread
            buf = array('f', [0]) * length
            pos = 0
            for i, value in enumerate(wet):
                out = buf[pos]
                wet[i] = out - value
                buf[pos] = value + out * .5
                pos += 1
                if pos == length: pos = 0
        for i in range(count):
            channel[i] = channel[i] * .72 + wet[i] * .28

    # The score's master envelope copies only a measured loudness shape.
    # Equalize slow chord-energy changes before the envelope; no limiter.
    energies = [math.sqrt(sum(left[i]**2 + right[i]**2 for i in range(a, min(count, a+RATE//2))) / RATE)
                for a in range(0, count, RATE//2)]
    for i in range(count):
        t = i / RATE
        block = max(0, t * 2 - .5)
        k = min(len(energies)-2, int(block))
        energy = energies[k] + (energies[k+1]-energies[k]) * (block-k)
        db = -31 + 21 * smooth(t / BEATS["plateau"][0]) if t < BEATS["plateau"][0] else -10 if t < FADE_START else -10 - 30 * smooth((t-FADE_START)/(SILENCE_START-FADE_START))
        envelope = 10 ** (db/20) / max(.01, energy)
        # Final 100 ms reaches digital silence before AAC's tail.
        envelope *= 1 - smooth((t-(SILENCE_START-.1))/.1)
        if t >= SILENCE_START: envelope = 0
        left[i] *= envelope
        right[i] *= envelope
    peak = max(max(map(abs, left)), max(map(abs, right)))
    # v2 master: calibrated plateau -14 LUFS (ebur128). The resulting
    # -2.90 dBFS peak misses the original -1 dBFS target; documented for review.
    gain = 10 ** ((-1-1.9)/20) / peak
    pcm = array('h')
    for l, r in zip(left, right):
        pcm.append(round(l * gain * 32767))
        pcm.append(round(r * gain * 32767))
    if sys.byteorder != 'little': pcm.byteswap()
    return pcm.tobytes()


def metrics(pcm):
    samples = array('h'); samples.frombytes(pcm)
    if sys.byteorder != 'little': samples.byteswap()
    curve = []
    for a in range(0, len(samples), RATE):
        part = samples[a:a+RATE]
        rms = math.sqrt(sum((x/32768)**2 for x in part)/len(part))
        curve.append(round(20*math.log10(max(1e-9, rms)), 3))
    return dict(duration=len(samples)/(RATE*2), peakDBFS=20*math.log10(max(map(abs,samples))/32768), rmsDBFS=curve,
                silentTailPeak=max(map(abs, samples[round(SILENCE_START*RATE)*2:]), default=0))


def decode(path, temporary):
    target = Path(temporary)/'decoded.wav'
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@48000', str(path), str(target)], check=True)
    # afconvert writes WAVE_FORMAT_EXTENSIBLE on newer macOS versions.
    # Parse only bounded RIFF PCM chunks instead of requiring Python 3.12.
    data = target.read_bytes()
    if len(data) > RATE*DURATION*4+1048576 or data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise RuntimeError('invalid or oversized decoded WAV')
    offset, pcm, valid = 12, None, False
    while offset+8 <= len(data):
        kind, size = struct.unpack_from('<4sI', data, offset)
        part = data[offset+8:offset+8+size]
        if len(part) != size: raise RuntimeError('truncated decoded WAV')
        if kind == b'fmt ':
            tag, channels, rate, _, _, bits = struct.unpack_from('<HHIIHH', part)
            valid = channels == 2 and rate == RATE and bits == 16 and (tag == 1 or (tag == 65534 and part[24:28] == b'\x01\0\0\0'))
        if kind == b'data': pcm = part
        offset += 8+size+(size%2)
    if not valid or pcm is None: raise RuntimeError('AAC decode format differs')
    return pcm



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--out', type=Path, default=DEST)
    parser.add_argument('--pcm-out', type=Path)
    args = parser.parse_args()
    started = time.monotonic()
    pcm = synthesize()
    digest = hashlib.sha256(pcm).hexdigest()
    if digest != EXPECTED_PCM:
        raise RuntimeError('PCM hash differs: ' + digest)
    with tempfile.TemporaryDirectory(prefix='open-intro-sound-') as temp:
        wav = Path(temp)/'intro.wav'
        with wave.open(str(wav), 'wb') as out:
            out.setnchannels(2); out.setsampwidth(2); out.setframerate(RATE); out.writeframes(pcm)
        if args.pcm_out: args.pcm_out.write_bytes(wav.read_bytes())
        if not args.check:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '128000', '-q', '127', str(wav), str(args.out)], check=True)
        committed = metrics(decode(args.out, temp))
        original = metrics(pcm)
        reference = dict(original, pcmSHA256=digest)
        reference_path = args.out.with_name('open-intro-reference.json')
        if args.check:
            if json.loads(reference_path.read_text()) != reference: raise RuntimeError('PCM reference differs')
        else:
            reference_path.write_text(json.dumps(reference, indent=2)+'\n')
        deviations = [abs(a-b) for a,b in zip(original['rmsDBFS'][:39], committed['rmsDBFS'][:39])]
        if abs(committed['duration']-DURATION) > .02 or max(deviations) > 1.5 or committed['silentTailPeak'] > 8:
            raise RuntimeError('AAC duration/curve/silent tail failed: ' + json.dumps(committed))
        print(json.dumps(dict(pcmSHA256=digest, pcm=original, aac=committed, maxCurveDeltaDB=max(deviations),
                              size=args.out.stat().st_size, runtimeSeconds=time.monotonic()-started), indent=2))


if __name__ == '__main__': main()
