"""Generates milestone 2 waveform test files (32-bit float WAV, 44.1 kHz, 4 s).

wave_mono.wav:   0.8·sin(2π·1Hz·t)
wave_stereo.wav: L = 0.8·sin(2π·1Hz·t), R = 0.4  -> mono mix 0.4·sin + 0.2
Usage: python3 gen_test_audio_m2.py <outdir>
"""
import os, struct, sys
import numpy as np

SR, DUR = 44100, 4.0


def write_float_wav(path, data, sr):
    frames, ch = data.shape
    payload = data.astype('<f4').tobytes()
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(payload)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 3, ch, sr, sr * ch * 4, ch * 4, 32))
        f.write(b'data' + struct.pack('<I', len(payload)) + payload)


def signals():
    n = int(SR * DUR)
    s = 0.8 * np.sin(2 * np.pi * np.arange(n) / SR)
    return {
        'wave_mono.wav': s[:, None],
        'wave_stereo.wav': np.stack([s, np.full(n, 0.4)], axis=1),
    }


if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, data in signals().items():
        write_float_wav(os.path.join(out, name), data, SR)
    print(f'Generated {len(signals())} files in {out}')
