#!/usr/bin/env python3
"""Self-contained BPM estimator. No third-party deps — uses ffmpeg to decode
audio to mono PCM, then onset-envelope autocorrelation to estimate tempo.

Accuracy is "bucket-grade" (good enough to sort tracks into BPM bands for the
warmup/sustain/release director), not lab-grade. Octave errors are folded into
a musical 70–180 BPM range.

Usage:
    analyze-bpm.py <file1> [file2 ...]
Prints one line per file: "<bpm>\t<path>"
"""
import sys
import subprocess
import array
import math

SR = 11025          # decode sample rate (mono)
HOP = 128           # samples per envelope frame
FRAME = 256         # energy window
FPS = SR / HOP      # envelope frames per second (~86.1)
BPM_MIN, BPM_MAX = 70.0, 180.0


def decode_pcm(path):
    """Decode any ffmpeg-readable file to mono s16le PCM samples."""
    cmd = [
        "ffmpeg", "-v", "quiet", "-i", path,
        "-ac", "1", "-ar", str(SR), "-f", "s16le", "-",
    ]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0 or not proc.stdout:
        return None
    samples = array.array("h")
    samples.frombytes(proc.stdout)
    return samples


def onset_envelope(samples):
    """Per-frame energy flux (positive differences) — a cheap onset signal."""
    n = len(samples)
    # Prefix sum of squared samples for O(1) windowed energy.
    sq = array.array("d", [0.0]) * (n + 1)
    acc = 0.0
    for i in range(n):
        s = samples[i]
        acc += float(s) * float(s)
        sq[i + 1] = acc

    env = []
    prev_energy = 0.0
    i = 0
    while i + FRAME <= n:
        energy = sq[i + FRAME] - sq[i]
        flux = energy - prev_energy
        env.append(flux if flux > 0 else 0.0)
        prev_energy = energy
        i += HOP

    # Normalize.
    peak = max(env) if env else 0.0
    if peak > 0:
        env = [v / peak for v in env]
    return env


def estimate_bpm(env):
    if len(env) < int(FPS * 4):  # need a few seconds
        return None
    lag_min = int(round(FPS * 60.0 / BPM_MAX))
    lag_max = int(round(FPS * 60.0 / BPM_MIN))
    best_lag, best_score = None, -1.0
    n = len(env)
    for lag in range(lag_min, lag_max + 1):
        score = 0.0
        for i in range(lag, n):
            score += env[i] * env[i - lag]
        # Slight bias toward mid-tempo to damp spurious slow peaks.
        if score > best_score:
            best_score = score
            best_lag = lag
    if not best_lag:
        return None
    bpm = FPS * 60.0 / best_lag
    # Fold octave errors into the musical range.
    while bpm < BPM_MIN:
        bpm *= 2
    while bpm > BPM_MAX:
        bpm /= 2
    return round(bpm)


def main():
    for path in sys.argv[1:]:
        samples = decode_pcm(path)
        if samples is None:
            print(f"ERR\t{path}", flush=True)
            continue
        env = onset_envelope(samples)
        bpm = estimate_bpm(env)
        print(f"{bpm if bpm else 'ERR'}\t{path}", flush=True)


if __name__ == "__main__":
    main()
