"""Checks milestone 10 acceptance criteria (min/max/RMS waveform columns).
Run from prototype/: python3 verify/verify_m10.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs (it plays audio briefly). Screenshots: verify/out/m10/*.png.
Only milestone 10 is checked. ONLY=2,5 runs selected criteria.
"""
import atexit, math, os, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav, signals as m2_signals  # noqa: E402

OUT = 'verify/out/m10'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = ('horizontal', 'vertical')
PANES = ('navigator', 'main')
KEYS = ['timeOrientation', 'followPlayhead', 'loopEnabled', 'mainPaneMode', 'spectrogramWindowMs']


def run(c):
    return not ONLY or str(c) in ONLY


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


# Remember the user's settings that the test changes and restore them afterwards.
saved = {}
for k in KEYS:
    r = subprocess.run(['defaults', 'read', DOMAIN, k], capture_output=True, text=True)
    if r.returncode == 0:
        saved[k] = r.stdout.strip()


def restore_defaults():
    for k in KEYS:
        subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)
        if k in saved:
            v = saved[k]
            kind = '-bool' if k in ('followPlayhead', 'loopEnabled') else ('-float' if k == 'spectrogramWindowMs' else '-string')
            if kind == '-bool':
                v = 'true' if v == '1' else 'false'
            subprocess.run(['defaults', 'write', DOMAIN, k, kind, v], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)
atexit.register(restore_defaults)

# --- Test audio ---
os.makedirs(AUDIO, exist_ok=True)
rng = np.random.default_rng(10)
FILES = {}
for name, data in m2_signals().items():
    FILES[name] = (data, 44100)
# Rich mono: a decaying 220 Hz tone, silence 2–3 s, a noise burst; 6 s.
t = np.arange(6 * 44100) / 44100
rich = 0.8 * np.exp(-t) * np.sin(2 * np.pi * 220 * t)
rich[(t >= 2) & (t < 3)] = 0
burst = (t >= 3) & (t < 4.5)
rich[burst] = 0.5 * rng.standard_normal(burst.sum()).clip(-1.6, 1.6)
FILES['rich.wav'] = (rich[:, None], 44100)
# 8 kHz mono: 300 Hz tone plus a little noise, 2 s.
t8 = np.arange(2 * 8000) / 8000
FILES['low8k.wav'] = ((0.6 * np.sin(2 * np.pi * 300 * t8) + 0.05 * rng.standard_normal(t8.size))[:, None], 8000)
for name, (data, sr) in FILES.items():
    write_float_wav(f'{AUDIO}/{name}', data, sr)
LONG = f'{AUDIO}/long.wav'
LONG_DUR = 600.0
if not os.path.exists(LONG):
    n = int(LONG_DUR * 44100)
    ln = (0.3 * rng.standard_normal(n)).astype(np.float32)
    write_float_wav(LONG, np.stack([ln, np.roll(ln, 1000)], axis=1), 44100)


def mono_of(data):
    d = data.astype(np.float32)
    return d.sum(axis=1, dtype=np.float32) * np.float32(1 / d.shape[1])


# 1. Builds
r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()


# --- Reference (the spec's column definition) ---
def ref_columns(x, sr, start, end, count):
    frames = len(x)
    h = (end - start) / count
    last = float(frames - 1)
    out = {}
    for j in range(count):
        p0 = (start + j * h) * sr
        p1 = (start + (j + 1) * h) * sr
        a, b = max(p0, 0.0), min(p1, last)
        if a > b:
            continue

        def interp(p):
            i0 = int(p)
            i1 = min(i0 + 1, frames - 1)
            f = np.float32(p - i0)
            return np.float32(x[i0] * (np.float32(1) - f) + x[i1] * f)
        ea, eb = interp(a), interp(b)
        lo, hi = int(math.floor(a)) + 1, int(math.ceil(b))
        inner = x[lo:hi] if hi > lo else x[:0]
        vals = np.concatenate([inner, [ea, eb]]).astype(np.float64)
        out[j] = (vals.min(), vals.max(), math.sqrt((vals ** 2).sum() / len(vals)))
    return out


def pane_info(s, pane):
    w = s.state['waveforms'][pane]
    horizontal = s.state['orientation'] == 'horizontal'
    length = w['size']['width'] if horizontal else w['size']['height']
    cross = w['size']['height'] if horizontal else w['size']['width']
    return w, int(math.floor(length)), cross, horizontal


def compare_values(s, pane, x, sr):
    w, count, _, _ = pane_info(s, pane)
    v = s.state['view']
    ref = ref_columns(x, sr, v['start'], v['end'], count)
    got = {c['j']: (c['min'], c['max'], c['rms']) for c in w['columns']}
    if set(got) != set(ref):
        return False, f'columns {len(got)} vs reference {len(ref)}; missing {sorted(set(ref) - set(got))[:5]}, extra {sorted(set(got) - set(ref))[:5]}', got, ref
    err = max((max(abs(a - b) for a, b in zip(got[j], ref[j])) for j in ref), default=0)
    return err <= 1e-5, f'max error {err:.2e} over {len(ref)} columns', got, ref


def session(name, opens, orientation):
    s = Session(name, opens=opens, orientation=orientation)
    s.command('resize 1000,700')
    s.command('follow off')
    s.command('mode waveform')
    s.dump()
    return s


def zoom_full(s, dur):
    s.command(f'view -0.05,{dur + 0.05}')
    s.dump()


# 2, 3, 4. Values, drawing, continuity
def bars_ok(s, pane):
    w, count, cross, horizontal = pane_info(s, pane)
    g = 10 ** (s.state['amplitudeZoomDB'] / 20)
    v = s.state['view']
    show_rms = (v['end'] - v['start']) / count > 0.001

    def pos(v):
        return cross / 2 * (1 - v * g) if horizontal else cross / 2 * (1 + v * g)

    def clip(lo, hi):
        a, b = max(lo, 0), min(hi, cross)
        return [a, b] if b > a else None
    bad = []
    length = count  # integer pane sizes
    for c in w['columns']:
        lo, hi = sorted((pos(c['min']), pos(c['max'])))
        if hi - lo < 1:
            m = (lo + hi) / 2
            lo, hi = m - 0.5, m + 0.5
        r0, r1 = sorted((pos(-c['rms']), pos(c['rms'])))
        exp_bar, exp_rms = clip(lo, hi), (clip(r0, r1) if show_rms else None)
        exp_axis = [c['j'] * 1.0, c['j'] + 1.0]

        def same(a, b):
            return (a is None and b is None) or (a is not None and b is not None and all(abs(p - q) < 1e-3 for p, q in zip(a, b)))
        if not (same(c['bar'], exp_bar) and same(c['rmsBar'], exp_rms) and same(c['axis'], exp_axis)):
            bad.append((c, exp_bar, exp_rms))
    return not bad, f'{len(bad)} of {len(w["columns"])} columns differ; first: {bad[:1]}'


def continuity_ok(s, pane):
    w = s.state['waveforms'][pane]
    cols = sorted(w['columns'], key=lambda c: c['j'])
    gaps = [(a['j'], b['j']) for a, b in zip(cols, cols[1:])
            if b['j'] == a['j'] + 1 and max(a['min'], b['min']) > min(a['max'], b['max']) + 1e-7]
    return not gaps, f'gaps at {gaps[:5]}'


if run(2) or run(3) or run(4):
    for o in ORIENTATIONS:
        for name in ('wave_mono.wav', 'wave_stereo.wav', 'rich.wav', 'low8k.wav'):
            data, sr = FILES[name]
            x = mono_of(data)
            dur = len(x) / sr
            s = session(f'{o}_{name[:-4]}', [f'{AUDIO}/{name}'], o)
            views = [('full', -0.05, dur + 0.05), ('middle', 1.0, 1.5)]
            if name == 'low8k.wav':
                views += [('max', 0.5, 0.6), ('maxEnd', dur - 0.05, dur + 0.05), ('maxStart', -0.05, 0.05)]
            if name == 'rich.wav':
                views += [('silence', 1.9, 3.1)]
            for tag, a, b in views:
                s.command(f'view {a},{b}')
                s.command('amplitude 0')
                s.dump()
                for pane in PANES:
                    _, count, _, _ = pane_info(s, pane)
                    spc = (s.state['view']['end'] - s.state['view']['start']) * sr / count
                    if run(2):
                        ok, detail, got, ref = compare_values(s, pane, x, sr)
                        check(2, f'{o} {name} {tag} {pane}: values match the reference ({spc:.2f} samples/column)', ok, detail)
                        if tag == 'full':
                            first, lastj = min(ref), max(ref)
                            check(2, f'{o} {name} {tag} {pane}: margin columns left out, {len(ref)} of {count} drawn '
                                     f'(first {first}, last {lastj})', 0 < first and lastj < count - 1 and set(got) == set(ref))
                    if run(3):
                        ok, detail = bars_ok(s, pane)
                        spp = (s.state['view']['end'] - s.state['view']['start']) / count * 1000
                        rms_n = sum(1 for c in s.state['waveforms'][pane]['columns'] if c['rmsBar'])
                        check(3, f'{o} {name} {tag} {pane}: bars follow from the values ({spp:.3f} ms/column, '
                                 f'{rms_n} RMS spans)', ok and (spp > 1 or rms_n == 0), detail)
                    if run(4) and tag in ('full', 'middle', 'max'):
                        ok, detail = continuity_ok(s, pane)
                        check(4, f'{o} {name} {tag} {pane}: neighbouring columns touch', ok, detail)
                if run(3) and tag == 'silence':
                    w, count, cross, _ = pane_info(s, 'main')
                    silent = [c for c in w['columns'] if c['min'] == 0 and c['max'] == 0]
                    ok = len(silent) > 100 and all(c['bar'] and abs(c['bar'][1] - c['bar'][0] - 1) < 1e-6
                                                   and abs(sum(c['bar']) / 2 - cross / 2) < 1e-6 and c['rmsBar'] is None
                                                   for c in silent)
                    check(3, f'{o} silent stretch: {len(silent)} columns 1 point thick on the zero line, no RMS bar', ok)
                if run(3) and name == 'rich.wav' and tag == 'middle':
                    before = {p: s.state['waveforms'][p]['columns'] for p in PANES}
                    s.command('amplitude 20')
                    s.dump()
                    for pane in PANES:
                        w, _, cross, _ = pane_info(s, pane)
                        same_vals = [(c['min'], c['max'], c['rms']) for c in w['columns']] == \
                                    [(c['min'], c['max'], c['rms']) for c in before[pane]]
                        ok, detail = bars_ok(s, pane)
                        clipped = sum(1 for c in w['columns'] if c['bar'] and (c['bar'][0] == 0 or c['bar'][1] == cross))
                        check(3, f'{o} +20 dB {pane}: values unchanged, bars ×10 and clipped ({clipped} columns at the edges)',
                              ok and same_vals and clipped > 10, detail)
                    s.command('amplitude 0')
                if o == 'horizontal' and name == 'rich.wav' or name == 'low8k.wav' and tag == 'max':
                    s.snapshot(tag)
            s.quit()

# 5. Speed and caching
if run(5):
    for o in ORIENTATIONS:
        s = session(f'{o}_long', [LONG], o)
        times = {}
        for i in range(3):  # recompute a few times with slightly different full views
            s.command(f'view -0.05,{LONG_DUR + 0.05 - i * 0.001}')
            s.dump()
            for pane in PANES:
                times.setdefault(pane, []).append(s.state['waveforms'][pane]['lastColumnsMs'])
        for pane in PANES:
            w, count, _, _ = pane_info(s, pane)
            spc = LONG_DUR * 44100 / count
            check(5, f'{o} {pane}: 10-minute file fully zoomed out ({spc:.0f} samples/column), columns in '
                     f'{max(times[pane]):.2f} ms (< 5)', max(times[pane]) < 5, str(times[pane]))
        s.command('playhead 100')
        s.input('key space')
        time.sleep(0.3)
        s.dump()
        c0 = {p: s.state['waveforms'][p]['columnComputations'] for p in PANES}
        p0 = s.state['playback']['playhead']
        time.sleep(0.8)
        s.dump()
        c1 = {p: s.state['waveforms'][p]['columnComputations'] for p in PANES}
        p1 = s.state['playback']['playhead']
        playing = s.state['playback']['playing']
        s.input('key space')
        check(5, f'{o}: during playback (playhead {p0:.2f} → {p1:.2f} s) the columns are reused, not recomputed',
              playing and p1 - p0 > 0.5 and c0 == c1, f'{c0} → {c1}')
        s.quit()

# 6. Appearance (screenshots for the human)
if run(6):
    for o in ORIENTATIONS:
        s = session(f'{o}_look', [f'{AUDIO}/rich.wav'], o)
        zoom_full(s, 6.0)
        s.snapshot('zoomed_out')
        s.command('view 0.10,0.15')
        s.command('view 0.10,0.20')
        s.snapshot('zoomed_in')
        s.command('view 2.5,4.5')
        s.snapshot('burst_2s')
        s.command('view 2.9,3.4')
        s.snapshot('burst_edge')
        zoom_full(s, 6.0)
        s.command('mode spectrogram')
        s.command('playhead 1.0')
        time.sleep(1.0)
        s.dump()
        aw = s.state['waveforms']['navigator']['analysisWindow']
        check(6, f'{o}: spectrogram mode, the navigator keeps its columns and the analysis window',
              bool(aw) and len(s.state['waveforms']['navigator']['columns']) > 0)
        s.snapshot('spectrogram')
        s.command('mode waveform')
        s.quit()
    print(f'Screenshots for the human check: {OUT}/*_look_*.png')

# 7. Amplitude zoom direction
if run(7):
    for o in ORIENTATIONS:
        s = session(f'{o}_ampdir', [f'{AUDIO}/rich.wav'], o)
        zoom_full(s, 6.0)
        c = s.at('main', 0.5)
        cases = [('vertical delta −40', 0, -40, +1), ('vertical delta +40', 0, 40, -1)] if o == 'horizontal' else \
                [('horizontal delta +40', 40, 0, +1), ('horizontal delta −40', -40, 0, -1)]
        for label, dx, dy, sign in cases:
            s.command('amplitude 20')
            s.dump()
            before = s.state['amplitudeZoomDB']
            s.input(f'scroll {c[0]:.1f} {c[1]:.1f} {dx} {dy} cmd')
            after = s.state['amplitudeZoomDB']
            check(7, f'{o}: ⌘-scroll {label} {"raises" if sign > 0 else "lowers"} the amplitude zoom '
                     f'({before:.2f} → {after:.2f} dB)', (after - before) * sign > 1)
        s.quit()

print(f'\n{sum(results)} of {len(results)} checks passed')
sys.exit(0 if all(results) else 1)
