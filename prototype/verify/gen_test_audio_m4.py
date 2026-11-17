"""Milestone 4 test audio: 10 s stereo 44.1 kHz float WAV of seeded white noise at about -12 dBFS
(left and right different), so any rendered range can be located exactly.
Usage: python3 gen_test_audio_m4.py <outdir>"""
import os, sys
import numpy as np
from gen_test_audio_m2 import write_float_wav

SR, DUR = 44100, 10.0


def noise():
    rng = np.random.default_rng(1234)
    # Uniform in ±0.25·√3 has an RMS of 0.25 (−12 dBFS).
    return (rng.uniform(-1, 1, (int(SR * DUR), 2)) * 0.25 * np.sqrt(3)).astype(np.float32)


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    write_float_wav(os.path.join(out, 'noise.wav'), noise(), SR)
    print('Generated noise.wav')
