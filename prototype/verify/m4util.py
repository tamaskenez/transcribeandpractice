"""Shared helpers of the milestone 4 verification scripts."""
import json, os, struct, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
from m3session import Session, build_driver, BIN  # noqa: E402
from gen_test_audio_m4 import noise, SR  # noqa: E402

OUT = 'verify/out/m4'
m3session.OUT = OUT  # sessions write their command files and dumps here
AUDIO = f'{OUT}/audio'
NOISE = f'{AUDIO}/noise.wav'
SINE = 'verify/out/m3/audio/wave_mono.wav'
DOMAIN = 'com.tamaskenez.transcribeandpractice.prototype'
D = 10.0
results = []
X = None


def check(criterion, desc, ok, detail=''):
    results.append(bool(ok))
    print(f"{'PASS' if ok else 'FAIL'}  [{criterion}] {desc}" + (f'  -- {detail}' if detail and not ok else ''), flush=True)


def P(xy):
    return f'{xy[0]:.2f} {xy[1]:.2f}'


def read_wav(path):
    b = open(path, 'rb').read()
    ch = struct.unpack('<H', b[22:24])[0]
    i = b.index(b'data')
    n = struct.unpack('<I', b[i + 4:i + 8])[0]
    return np.frombuffer(b[i + 8:i + 8 + n], '<f4').reshape(-1, ch)


def f(t):
    return int(round(t * SR))


def pb(s):
    return s.state['playback']


def wait_until(s, cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        s.dump()
        if cond(pb(s)):
            return True
        time.sleep(0.05)
    return False


def wait_playhead(s, t, timeout=5.0):
    return wait_until(s, lambda p: p['playing'] and p['playhead'] >= t, timeout)


class Recording:
    def __init__(self, s, name):
        self.s, self.path = s, os.path.abspath(f'{OUT}/{name}.wav')
        s.command(f'record {self.path}')

    def stop(self):
        self.s.command('record stop')
        return read_wav(self.path)


def segments_ok(rec, parts):
    """rec must be the concatenation of the file ranges `parts` [(t0, t1|None)], the last one may
    be cut short (None = whatever length remains)."""
    i = 0
    for k, (t0, t1) in enumerate(parts):
        if i == len(rec) and k > 0:
            break
        a = f(t0)
        n = min(len(rec) - i if t1 is None else f(t1) - a, len(rec) - i)
        if n <= 0 or not np.array_equal(rec[i:i + n], X[a:a + n]):
            return False, f'part {k} ({t0}–{t1}) at {i}, rec length {len(rec)}'
        i += n
    return i == len(rec), f'consumed {i} of {len(rec)}'


def looped(first, lo, hi):
    """Parts of a looping playback: first–hi, then lo–hi repeated (the recording may stop anywhere)."""
    return [(first, hi)] + [(lo, hi)] * 20


