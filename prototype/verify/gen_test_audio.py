"""Generates milestone 1 test audio with known properties, plus expected.json.

Each file holds sine tones at f = sr/100 (exactly 100 samples per period, so a sample lands on
every peak), 3 s long. Channel amplitudes: ch1 0.5, ch2 0.25.
Usage: python3 gen_test_audio.py <outdir>
"""
import json, math, os, struct, subprocess, sys
import numpy as np

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
DUR = 3.0
AMPS = [0.5, 0.25]


def write_float_wav(path, data, sr):
    frames, ch = data.shape
    payload = data.astype('<f4').tobytes()
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(payload)) + b'WAVE')
        f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 3, ch, sr, sr * ch * 4, ch * 4, 32))
        f.write(b'data' + struct.pack('<I', len(payload)) + payload)


def source(sr, ch):
    n = int(DUR * sr)
    t = np.arange(n)
    return np.stack([AMPS[c] * np.sin(2 * np.pi * t / 100) for c in range(ch)], axis=1), n


# name, sample rate, channels, converter args, lossless
cases = [
    ('mono_44100_16bit.wav', 44100, 1, ['afconvert', '-f', 'WAVE', '-d', 'LEI16'], True),
    ('stereo_48000_24bit.wav', 48000, 2, ['afconvert', '-f', 'WAVE', '-d', 'LEI24'], True),
    ('stereo_44100.aiff', 44100, 2, ['afconvert', '-f', 'AIFF', '-d', 'BEI16'], True),
    ('mono_48000_float.caf', 48000, 1, ['afconvert', '-f', 'caff', '-d', 'LEF32'], True),
    ('stereo_44100_alac.m4a', 44100, 2, ['afconvert', '-f', 'm4af', '-d', 'alac'], True),
    ('mono_48000.flac', 48000, 1, ['afconvert', '-f', 'flac', '-d', 'flac'], True),
    ('stereo_44100.flac', 44100, 2, ['afconvert', '-f', 'flac', '-d', 'flac'], True),
    ('stereo_44100_aac.m4a', 44100, 2, ['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '256000'], False),
    ('mono_48000_aac.m4a', 48000, 1, ['afconvert', '-f', 'm4af', '-d', 'aac', '-b', '128000'], False),
    ('stereo_44100.mp3', 44100, 2, ['lame', '--quiet', '-b', '256'], False),
    ('mono_48000.mp3', 48000, 1, ['lame', '--quiet', '-b', '128', '-m', 'm'], False),
]

expected = {'valid': {}, 'invalid': []}
for name, sr, ch, cmd, lossless in cases:
    data, n = source(sr, ch)
    src = os.path.join(out, f'_src_{sr}_{ch}.wav')
    write_float_wav(src, data, sr)
    subprocess.run(cmd + [src, os.path.join(out, name)], check=True)
    expected['valid'][name] = {
        'sampleRate': sr, 'channels': ch, 'frames': n, 'duration': n / sr, 'lossless': lossless,
        'peakDBFS': [20 * math.log10(AMPS[c]) for c in range(ch)],
        'rmsDBFS': [20 * math.log10(AMPS[c] / math.sqrt(2)) for c in range(ch)],
    }
for f in os.listdir(out):
    if f.startswith('_src_'):
        os.remove(os.path.join(out, f))

with open(os.path.join(out, 'not_audio.wav'), 'w') as f:
    f.write('This is a text file, not audio.\n')
# Cut inside the container index (moov atom, at the start of the file): undecodable.
whole = open(os.path.join(out, 'stereo_44100_aac.m4a'), 'rb').read()
with open(os.path.join(out, 'damaged.m4a'), 'wb') as f:
    f.write(whole[:2000])
expected['invalid'] = ['not_audio.wav', 'damaged.m4a']

with open(os.path.join(out, 'expected.json'), 'w') as f:
    json.dump(expected, f, indent=2)
print(f'Generated {len(cases)} valid and 2 invalid files in {out}')
