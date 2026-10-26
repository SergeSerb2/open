#!/usr/bin/env python3
"""Generate Open's own sounds with the standard library, then macOS afconvert.

No recorded or reference-app audio is used. The PCM samples use a fixed seed.
PCM hashes are pinned below. --check verifies the generated samples and the
decoded committed resources. CAF byte differences are informational only.
"""
import argparse
import hashlib
import math
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import wave

RATE = 48000
SEED = 0x4F50454E
EXPECTED_PCM = {
    "open-capture": "4634a95aa59fe3bcb96f220935544790e2f388b82edf03050d0b223e9e89c52f",
    "open-event": "72ef269b2a3ba81dab4ef79a99dcaf081014ac2aea17d8905c96bbd10d19ef55",
}


def capture():
    samples = [0.0] * round(0.45 * RATE)
    noise = random.Random(SEED)
    for onset in (0.025, 0.055):
        filtered = 0.0
        for index in range(round(0.012 * RATE)):
            filtered = 0.35 * noise.uniform(-1.0, 1.0) + 0.65 * filtered
            envelope = math.exp(-index / (0.0025 * RATE))
            samples[round(onset * RATE) + index] += filtered * envelope
    for index in range(round(0.040 * RATE)):
        t = index / RATE
        envelope = math.sin(math.pi * t / 0.040) ** 2
        samples[round(0.065 * RATE) + index] += 0.3 * envelope * math.sin(2 * math.pi * 2000 * t)
    return normalize(samples, -6)


def event():
    samples = [0.0] * round(1.1 * RATE)
    for onset, frequency in ((0.0, 1046.5), (0.3, 1568.0)):
        start = round(onset * RATE)
        for index in range(start, len(samples)):
            t = (index - start) / RATE
            envelope = min(t / 0.005, 1.0) * math.exp(-max(0.0, t - 0.005) / 0.25)
            samples[index] += envelope * math.sin(2 * math.pi * frequency * t)
    return normalize(samples, -8)


def normalize(samples, db):
    gain = (10 ** (db / 20)) / max(abs(sample) for sample in samples)
    return b"".join(struct.pack("<h", round(sample * gain * 32767)) for sample in samples)


def generate(destination, verify):
    destination = Path(destination)
    if not verify:
        destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="open-generated-sounds-") as temporary:
        for name, samples in (("open-capture", capture()), ("open-event", event())):
            digest = hashlib.sha256(samples).hexdigest()
            if digest != EXPECTED_PCM[name]:
                raise RuntimeError(f"generated PCM hash differs for {name}: {digest}")
            wav = Path(temporary) / (name + ".wav")
            caf = Path(temporary) / (name + ".caf")
            with wave.open(str(wav), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(RATE)
                output.writeframes(samples)
            subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16@48000", str(wav), str(caf)], check=True)
            data = caf.read_bytes()
            target = destination / (name + ".caf")
            if verify:
                decoded = Path(temporary) / (name + "-committed.wav")
                subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", str(target), str(decoded)], check=True)
                with wave.open(str(decoded), "rb") as source:
                    committed = source.readframes(source.getnframes())
                if hashlib.sha256(committed).hexdigest() != EXPECTED_PCM[name]:
                    raise RuntimeError(f"committed PCM differs: {target.name}")
                print(f"{name}.caf container byte-identical (informational): {target.read_bytes() == data}")
            else:
                target.write_bytes(data)
            print(f"{name} PCM SHA-256 {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "Packages/OpenKit/Sources/OpenFeatures/Resources/Sounds")
    args = parser.parse_args()
    generate(args.out, args.check)
