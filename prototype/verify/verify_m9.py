"""Checks milestone 9 acceptance criteria (spectrum pane, piano keys, analysis window, zoom axis).
Run from prototype/: python3 verify/verify_m9.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs (it also plays audio briefly). Screenshots: verify/out/m9/*.png.
Only milestone 9 is checked. ONLY=3,5 runs selected criteria.
"""
import atexit, math, os, struct, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m9'
os.makedirs(OUT, exist_ok=True)
m3session.OUT = m4util.OUT = OUT
m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
TONES = f'{AUDIO}/tones.wav'
SR = 44100
KEYS = ['mainPaneMode', 'spectrogramWindowMs']
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}
ORIENTATIONS = ('horizontal', 'vertical')


def run(c):
    return not ONLY or str(c) in ONLY


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


def reset_defaults():
    for k in KEYS:
        subprocess.run(['defaults', 'delete', DOMAIN, k], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)
atexit.register(reset_defaults)

# --- Test audio (as milestone 8): separate tones, a chord, silence between ---
TONE_LIST = [(0.5, 2.5, 110.0, -6.0, 'A2'), (3.0, 5.0, 440.0, -20.0, 'A4'), (5.5, 7.5, 4186.009, -40.0, 'C8')]
CHORD = (8.0, 10.0, [261.626, 329.628, 391.995], -20.0)
DUR = 10.5


def tones_signal():
    t = np.arange(int(DUR * SR)) / SR
    x = np.zeros_like(t)
    for a, b, f, db, _ in TONE_LIST:
        m = (t >= a) & (t < b)
        x[m] += 10 ** (db / 20) * np.sin(2 * np.pi * f * t[m])
    a, b, fs_, db = CHORD
    m = (t >= a) & (t < b)
    for f in fs_:
        x[m] += 10 ** (db / 20) * np.sin(2 * np.pi * f * t[m])
    return x.astype(np.float32)


os.makedirs(AUDIO, exist_ok=True)
X = tones_signal()
write_float_wav(TONES, X.reshape(-1, 1), SR)
X64 = X.astype(np.float64)

# 1. Builds
r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
reset_defaults()


# --- Helpers ---
def session(name, orientation='horizontal', opens=(TONES,), size=(1000, 700)):
    s = Session(name, opens=opens, orientation=orientation)
    s.command(f'resize {size[0]},{size[1]}')
    s.bring_to_front()
    s.dump()
    return s


def spec(s):
    return s.state['spectrum']


def gauss(n):
    k = np.arange(n) - (n - 1) / 2
    return np.exp(-0.5 * (2.5 * k / ((n - 1) / 2)) ** 2)


def window_n(ms, fs=SR):
    n = 2.5 * ms / 1000 * fs + 1
    return min(2 * math.floor((n - 1) / 2 + 0.5) + 1, 65535)


def row_freq(r):
    return 440 * 2 ** ((21 - 0.5 + (r + 0.5) / 14 - 69) / 12)


def reference_column(centre, n, rows):
    """Levels (dB) at the given absolute rows for a window of n samples centred at `centre`."""
    w = gauss(n)
    h = (n - 1) // 2
    seg = np.zeros(n)
    lo, hi = centre - h, centre + h + 1
    a, b = max(lo, 0), min(hi, len(X64))
    seg[a - lo:b - lo] = X64[a:b]
    mag = np.abs(np.fft.rfft(seg * w, 65536))
    bins = np.array([row_freq(r) for r in rows]) * 65536 / SR
    i0 = np.floor(bins).astype(int)
    t = bins - i0
    m = mag[i0] * (1 - t) + mag[i0 + 1] * t
    return 20 * np.log10(np.maximum(m * 2 / w.sum(), 1e-30))


def semitone_pos(f):
    """Position in semitones above the range's low edge (A0 − ½)."""
    return 12 * math.log2(f / 440) + 69 - 20.5


def read_snapshot(path):
    bmp = path[:-4] + '.bmp'
    subprocess.run(['sips', '-s', 'format', 'bmp', path, '--out', bmp], capture_output=True, check=True)
    b = open(bmp, 'rb').read()
    off = struct.unpack('<I', b[10:14])[0]
    w, h = struct.unpack('<ii', b[18:26])
    bpp = struct.unpack('<H', b[28:30])[0] // 8
    stride = (w * bpp + 3) // 4 * 4
    a = np.frombuffer(b[off:off + stride * abs(h)], np.uint8).reshape(abs(h), stride)[:, :w * bpp].reshape(abs(h), w, bpp)
    if h > 0:
        a = a[::-1]
    return a[:, :, 2::-1].astype(int)


class Shot:
    """A window screenshot, addressed in window-content coordinates (the dumped pane frames)."""
    def __init__(self, s, tag):
        s.snapshot(tag)
        self.img = read_snapshot(os.path.abspath(f'{OUT}/{s.name}_{tag}.png'))
        win = s.state['screenFrames']['window']
        self.scale = self.img.shape[1] / win['width']
        # Content origin within the screenshot: from a pane's screen and content frames.
        sf, pf = s.state['screenFrames']['main'], s.state['paneFrames']['main']
        self.ox = sf['x'] - pf['x'] - win['x']
        self.oy = sf['y'] - pf['y'] - win['y']

    def region(self, x0, y0, x1, y1):
        """Pixels of a content-coordinate rectangle."""
        sc = self.scale
        return self.img[int((y0 + self.oy) * sc):int((y1 + self.oy) * sc), int((x0 + self.ox) * sc):int((x1 + self.ox) * sc)]

    def px(self, x, y):
        sc = self.scale
        return self.img[int((y + self.oy) * sc), int((x + self.ox) * sc)]


def frames(s):
    pf = s.state['paneFrames']
    return {k: pf.get(k) for k in ('navigator', 'navigatorWaveform', 'main', 'spectrum')}


def covered_point(s, along=60, cross=0.5):
    """Screen point inside the spectrum pane: `along` points from its edge along the time axis."""
    sp = s.state['paneFrames']['spectrum']
    main_s, main_p = s.state['screenFrames']['main'], s.state['paneFrames']['main']
    dx, dy = main_s['x'] - main_p['x'], main_s['y'] - main_p['y']
    if s.state['orientation'] == 'horizontal':
        return sp['x'] + dx + along, sp['y'] + dy + cross * sp['height']
    return sp['x'] + dx + cross * sp['width'], sp['y'] + dy + along


def time_at_screen(s, p):
    main = s.state['screenFrames']['main']
    v0, v1 = s.view()
    if s.state['orientation'] == 'horizontal':
        return v0 + (p[0] - main['x']) / main['width'] * (v1 - v0)
    return v0 + (p[1] - main['y']) / main['height'] * (v1 - v0)


# 2. Layout
if run(2):
    s = session('c2_nofile', opens=())
    s.command('mode spectrogram')
    s.dump()
    check(2, 'no file: no spectrum pane', not spec(s)['shown'] and 'spectrum' not in s.state['paneFrames'],
          str(spec(s)))
    s.quit()
    for o in ORIENTATIONS:
        s = session(f'c2_{o}', orientation=o)
        s.command('mode waveform')
        s.dump()
        fw = frames(s)
        check(2, f'{o}: waveform mode: no spectrum pane', not spec(s)['shown'] and fw['spectrum'] is None, str(fw))
        s.snapshot('waveform')
        s.command('mode spectrogram')
        s.dump()
        fs_ = frames(s)
        sp, m = fs_['spectrum'], fs_['main']
        if o == 'horizontal':
            ok = sp and sp['x'] == m['x'] and sp['y'] == m['y'] and sp['width'] == 120 and sp['height'] == m['height']
        else:
            ok = sp and sp['x'] == m['x'] and sp['y'] + sp['height'] == m['y'] + m['height'] \
                and sp['height'] == 120 and sp['width'] == m['width']
        check(2, f'{o}: spectrum pane at the main pane\'s {"left" if o == "horizontal" else "bottom"} edge, 120 pt, '
                 'full cross size', ok, f'spectrum {sp} main {m}')
        same = all(fw[k] == fs_[k] for k in ('navigator', 'navigatorWaveform', 'main'))
        check(2, f'{o}: navigator and main pane frames unchanged by the spectrum pane (time axes aligned)', same,
              f'{fw} vs {fs_}')
        s.snapshot('spectrogram')
        s.quit()


# 3. Spectrum levels
if run(3):
    for o in ORIENTATIONS:
        s = session(f'c3_{o}', orientation=o)
        s.command('mode spectrogram')
        for ms in (10, 50, 500):
            s.command(f'window {ms}')
            n = window_n(ms)
            for t, f, name in ((1.5, 110.0, 'A2'), (4.0, 440.0, 'A4'), (6.5, 4186.009, 'C8'), (9.0, None, 'chord'),
                               (0.0, None, 'start')):
                s.command(f'playhead {t}')
                s.dump()
                d = spec(s)
                centre = d.get('centreSample')
                lv = np.array([np.nan if v is None else v for v in d['levels']])
                rows = [d['firstRow'] + q for q in range(len(lv)) if not np.isnan(lv[q])]
                got = lv[~np.isnan(lv)]
                ref = reference_column(int(round(t * SR)), n, rows)
                mask = ref > -100
                diff = float(np.max(np.abs(ref[mask] - got[mask]))) if mask.any() else 0.0
                check(3, f'{o} {ms} ms {name}: centre sample {int(round(t * SR))}, levels match the reference '
                         f'(max diff {diff:.4f} dB)', centre == int(round(t * SR)) and diff <= 0.01,
                      f'centre {centre}, diff {diff}')
                if f is not None:
                    pos = semitone_pos(f)
                    q_lo, q_hi = d['firstRow'] / 14, (d['firstRow'] + len(lv)) / 14
                    if q_lo <= pos - 0.5 and pos + 0.5 <= q_hi:
                        peak_row = rows[int(np.argmax(got))]
                        peak_pos = (peak_row + 0.5) / 14
                        check(3, f'{o} {ms} ms {name}: peak in its semitone', abs(peak_pos - pos) <= 0.5 + 1e-9,
                              f'peak at {peak_pos:.3f}, note at {pos:.3f}')
        # Playback: the column follows the playhead.
        s.command('window 50')
        s.command('playhead 3.0')
        s.input('key space')
        seen = []
        for _ in range(15):
            s.dump()
            d = spec(s)
            seen.append((d['centreSample'], s.state['playback']['playhead']))
            time.sleep(0.1)
        s.input('key space')
        centres = [c for c, _ in seen]
        close = all(abs(c / SR - p) < 0.15 for c, p in seen)
        check(3, f'{o}: during playback the centre sample follows the playhead', len(set(centres)) >= 5 and close,
              str(seen))
        s.quit()


# 4. Frequency alignment
if run(4):
    for o in ORIENTATIONS:
        s = session(f'c4_{o}', orientation=o)
        s.command('mode spectrogram')
        s.command('playhead 4.0')
        s.dump()

        def aligned(label):
            d, fv = spec(s), s.state['spectrogram']['freqView']
            main = s.state['waveforms']['main']['size']
            cross = main['height'] if o == 'horizontal' else main['width']
            ok = d['firstRow'] == round(fv['low'] * 14) and len(d['levels']) == round(cross)
            check(4, f'{o} {label}: spectrum rows = spectrogram rows (first {d["firstRow"]}, {len(d["levels"])} rows)',
                  ok, f'{d["firstRow"]} vs {fv["low"] * 14}, {len(d["levels"])} vs {cross}')

        aligned('initial')
        c = s.at('main', 0.6)
        if o == 'horizontal':
            s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0]:.1f} {c[1] + 70:.1f} option')
        else:
            s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0] - 70:.1f} {c[1]:.1f} option')
        aligned('after a frequency pan')
        # Screenshot: the A4 peak of the spectrum curve and the A4 line of the spectrogram.
        deadline = time.time() + 30
        while time.time() < deadline and (s.state['spectrogram']['busy'] or not s.state['spectrogram']['complete']):
            time.sleep(0.2)
            s.dump()
        sh = Shot(s, 'alignment')
        pf = s.state['paneFrames']
        sp, m = pf['spectrum'], pf['main']
        v0, v1 = s.view()
        def blue(p):
            return p[2] > p[0] + 60 and p[2] > 120
        if o == 'horizontal':
            x = m['x'] + (4.0 - v0) / (v1 - v0) * m['width']
            ys = np.arange(m['y'] + 1, m['y'] + m['height'] - 1, 1 / sh.scale)
            line = ys[int(np.argmax([sum(sh.px(x, y)) for y in ys]))]
            reach = [max([dx for dx in np.arange(0, 119, 1 / sh.scale) if blue(sh.px(sp['x'] + dx, y))], default=-1) for y in ys]
            peak = ys[int(np.argmax(reach))]
        else:
            y = m['y'] + (4.0 - v0) / (v1 - v0) * m['height']
            xs = np.arange(m['x'] + 1, m['x'] + m['width'] - 1, 1 / sh.scale)
            line = xs[int(np.argmax([sum(sh.px(x, y)) for x in xs]))]
            reach = [max([dy for dy in np.arange(0, 119, 1 / sh.scale) if blue(sh.px(x, sp['y'] + sp['height'] - 1 - dy))],
                         default=-1) for x in xs]
            peak = xs[int(np.argmax(reach))]
        check(4, f'{o}: A4 peak of the spectrum and A4 line of the spectrogram at the same cross position (±1 pt)',
              abs(peak - line) <= 1, f'spectrum peak {peak:.1f}, spectrogram line {line:.1f}')
        s.quit()


# 5. Keys
def expected_keys(low, cross, depth):
    pps = 14
    black_len = round(depth * 0.63)
    def pos(note):
        return round(((note - 21) - low) * pps)
    lines = []
    def add(kind, f0, f1, d0, d1):
        if f1 > 0 and f0 < cross:
            lines.append((kind, f0, f1, d0, d1))
    def across(kind, f, d0, d1):
        add(kind, f - 0.5, f + 0.5, d0, d1)
    def along(kind, d, f0, f1):
        add(kind, f0 - 0.5, f1 + 0.5, d - 0.5, d + 0.5)
    rl, rh = pos(21), pos(121)
    across('rangeLow', rl + 0.5, 0, depth)
    across('rangeHigh', rh - 0.5, 0, depth)
    along('backEnd', 0.5, rl, rh)
    along('frontEnd', depth - 0.5, rl, rh)
    for note in range(21, 121):
        f0, f1 = pos(note), pos(note + 1)
        if f1 < 0 or f0 > cross:
            continue
        if note % 12 in (1, 3, 6, 8, 10):
            across('blackSide', f0, 0, black_len)
            across('blackSide', f1, 0, black_len)
            along('blackEnd', black_len, f0, f1)
            across('whiteBoundaryMiddle', round((f0 + f1) / 2), black_len, depth)
        elif note < 120 and (note + 1) % 12 not in (1, 3, 6, 8, 10):
            across('whiteBoundaryEdge', f1, 0, depth)
    return sorted(lines)


if run(5):
    for o in ORIENTATIONS:
        for pan in ('C4', 'low end', 'high end'):
            s = session(f'c5_{o}_{pan.replace(" ", "")}', orientation=o)
            s.command('mode spectrogram')
            s.dump()
            c = s.at('main', 0.6)
            main = s.state['screenFrames']['main']
            if pan != 'C4':
                for _ in range(6):
                    toward_low = pan == 'low end'
                    if o == 'horizontal':
                        a, b = (main['y'] + main['height'] - 20, main['y'] + 20)
                        y0, y1 = (a, b) if toward_low else (b, a)  # dragging up shows lower notes
                        s.input(f'drag {c[0]:.1f} {y0:.1f} {c[0]:.1f} {y1:.1f} option')
                    else:
                        a, b = (main['x'] + 20, main['x'] + main['width'] - 20)
                        x0, x1 = (a, b) if toward_low else (b, a)
                        s.input(f'drag {x0:.1f} {c[1]:.1f} {x1:.1f} {c[1]:.1f} option')
            s.dump()
            d = spec(s)
            size = d['size']
            cross, depth = (size['height'], size['width']) if o == 'horizontal' else (size['width'], size['height'])
            low = s.state['spectrogram']['freqView']['low']
            got = sorted((k['kind'], *k['freq'], *k['depth']) for k in d['keyLines'])
            exp = expected_keys(low, cross, depth)
            same = len(got) == len(exp) and all(g[0] == e[0] and np.allclose(g[1:], e[1:], atol=1e-6) for g, e in zip(got, exp))
            kinds = {k[0] for k in got}
            check(5, f'{o} ({pan}): key outline lines follow the spec\'s geometry ({len(got)} lines, kinds {sorted(kinds)})',
                  same, f'got {len(got)} expected {len(exp)}; first diff '
                        f'{next(((g, e) for g, e in zip(got, exp) if g != e), None)}')
            # Back end at the left (horizontal) / top (vertical): the black keys' rects start at 0.
            backs = [k['rect'] for k in d['keyLines'] if k['kind'] == 'blackSide']
            at_back = all((r['x'] == 0) if o == 'horizontal' else (r['y'] == 0) for r in backs)
            check(5, f'{o} ({pan}): black keys start at the {"left" if o == "horizontal" else "top"} edge', at_back and backs,
                  str(backs[:3]))
            if pan != 'C4':
                want = 'rangeLow' if pan == 'low end' else 'rangeHigh'
                check(5, f'{o} ({pan}): the keyboard\'s outline edge at the range end is drawn', want in kinds, str(kinds))
            s.quit()
    # Screenshots: nothing drawn outside the pane.
    for o in ORIENTATIONS:
        s = session(f'c5_{o}_clip', orientation=o)
        # A view where the spectrogram next to the pane shows silence (2.5–3.0 s).
        if o == 'horizontal':
            s.command('view 2.375,5.375')
        else:
            s.command('view 0.38,3.38')
        s.command('playhead 4.2')
        s.command('mode waveform')
        s.dump()
        wf = Shot(s, 'waveform')
        s.command('mode spectrogram')
        deadline = time.time() + 30
        s.dump()
        while time.time() < deadline and (s.state['spectrogram']['busy'] or not s.state['spectrogram']['complete']):
            time.sleep(0.2)
            s.dump()
        sg = Shot(s, 'spectrogram')
        sp = s.state['paneFrames']['spectrum']
        if o == 'horizontal':
            ends = [(sp['x'], sp['y'] - 6, sp['x'] + sp['width'], sp['y'] - 1),
                    (sp['x'], sp['y'] + sp['height'] + 1, sp['x'] + sp['width'], sp['y'] + sp['height'] + 6)]
            side = (sp['x'] + sp['width'] + 2, sp['y'] + 2, sp['x'] + sp['width'] + 8, sp['y'] + sp['height'] - 2)
        else:
            ends = [(sp['x'] - 6, sp['y'], sp['x'] - 1, sp['y'] + sp['height'])]
            side = (sp['x'] + 2, sp['y'] - 8, sp['x'] + sp['width'] - 2, sp['y'] - 2)
        diffs = [float(np.max(np.abs(wf.region(*r) - sg.region(*r)))) for r in ends]
        check(5, f'{o}: beyond the pane\'s ends the screenshot is the same as in waveform mode (max diff {max(diffs)})',
              max(diffs) <= 8, str(diffs))
        side_px = sg.region(*side)
        check(5, f'{o}: the spectrogram next to the pane shows only its (silent, dark) content, no key lines '
                 f'(max channel {int(side_px.max())})', side_px.max() <= 40, str(side_px.max()))
        s.quit()


# 6. Input over the spectrum pane
if run(6):
    for o in ORIENTATIONS:
        s = session(f'c6_{o}', orientation=o)
        s.command('mode spectrogram')
        s.dump()
        p = covered_point(s)
        t_cov = time_at_screen(s, p)
        s.command('playhead 5.0')
        sel = (t_cov, t_cov + 2) if o == 'horizontal' else (t_cov - 2, t_cov)
        s.command(f'select {sel[0]},{sel[1]}')
        s.dump()
        sel0, ph0 = s.sel(), s.state['playback']['playhead']
        s.input(f'move {p[0]:.1f} {p[1]:.1f}')
        s.dump()
        cur = s.state['waveforms']['main']['cursor']
        check(6, f'{o}: over the spectrum pane (on a hidden selection edge): arrow cursor, no pointer line',
              cur == 'arrow' and s.state['ruler']['pointerAxis'] is None, f'{cur} {s.state["ruler"]["pointerAxis"]}')
        s.input(f'click {p[0]:.1f} {p[1]:.1f}')
        q = covered_point(s, along=100)
        s.input(f'drag {p[0]:.1f} {p[1]:.1f} {q[0]:.1f} {q[1]:.1f}')
        check(6, f'{o}: a click and a drag on the spectrum pane change neither the selection nor the playhead',
              s.sel() == sel0 and s.state['playback']['playhead'] == ph0, f'{sel0} → {s.sel()}, {ph0} → '
              f'{s.state["playback"]["playhead"]}')
        # A selection drag from the spectrogram onto the pane.
        a = s.at('main', 0.5)
        tp = time_at_screen(s, a)
        s.input(f'drag {a[0]:.1f} {a[1]:.1f} {p[0]:.1f} {p[1]:.1f}')
        got = s.sel()
        exp = sorted((tp, t_cov))
        px = (s.view()[1] - s.view()[0]) / s.length('main')
        check(6, f'{o}: a selection drag from the spectrogram continues over the pane', got is not None
              and abs(got[0] - exp[0]) <= 2 * px and abs(got[1] - exp[1]) <= 2 * px, f'{got} vs {exp}')
        s.quit()


# 7. Analysis window in the navigator
if run(7):
    for o in ORIENTATIONS:
        s = session(f'c7_{o}', orientation=o)
        s.command('mode waveform')
        s.command('playhead 4.0')
        s.dump()
        check(7, f'{o}: no analysis window in waveform mode', s.state['waveforms']['navigator']['analysisWindow'] is None)
        s.command('mode spectrogram')
        for ms, t in ((50, 4.0), (500, 4.0), (500, 6.0)):
            s.command(f'window {ms}')
            s.command(f'playhead {t}')
            s.dump()
            nav = s.state['waveforms']['navigator']
            lines = nav['analysisWindow']
            size = nav['size']
            hor = o == 'horizontal'
            length, cross = (size['width'], size['height']) if hor else (size['height'], size['width'])
            v0, v1 = s.view()
            pps = length / (v1 - v0)
            centre = (round(t * SR) / SR - v0) * pps
            n = window_n(ms)
            span = (n - 1) / SR * pps
            ax = (lambda q: q[0]) if hor else (lambda q: q[1])
            cr = (lambda q: q[1]) if hor else (lambda q: q[0])
            ok = lines is not None and len(lines) == 2
            detail = ''
            if ok:
                up, down = lines
                a0, a1 = ax(up[0]), ax(up[-1])
                ends = all(abs(cr(q) - cross / 2) < 1e-6 for q in (up[0], up[-1], down[0], down[-1]))
                extremes = sorted([min(cr(q) for q in up), max(cr(q) for q in up), min(cr(q) for q in down),
                                   max(cr(q) for q in down)])
                peaks = abs(extremes[0]) < 1e-6 and abs(extremes[-1] - cross) < 1e-6
                tol = 1e-6 * pps + 1e-6
                centred = abs((a0 + a1) / 2 - centre) <= tol
                spans = abs((a1 - a0) - span) <= tol
                ok = ends and peaks and centred and spans
                detail = f'ends {ends} peaks {extremes[0]:.3f}/{extremes[-1]:.3f} of {cross} centre {(a0 + a1) / 2:.3f} ' \
                         f'vs {centre:.3f} span {a1 - a0:.3f} vs {span:.3f}'
            check(7, f'{o} {ms} ms, playhead {t}: two mirrored curves centred at the playhead, N = {n} samples wide, '
                     'peaks at both edges, ends on the zero line', ok, detail)
            if t == 4.0:
                s.snapshot(f'window{ms}')
        s.quit()


# 8. ⌘-scroll zoom axis
if run(8):
    for o in ORIENTATIONS:
        s = session(f'c8_{o}', orientation=o)
        s.command('mode spectrogram')
        c = s.at('main', 0.6)

        def reset():
            s.command('view 2,6')
            s.command('amplitude 20')
            s.dump()
            return s.view(), s.state['amplitudeZoomDB']

        def gesture(first, rest):
            """first/rest: (along, across) deltas; returns (time zoomed, amplitude zoomed, zoomAxis)."""
            v, a = reset()
            def ev(d, phase):
                along, across = d
                dx, dy = (along, across) if o == 'horizontal' else (across, along)
                return f'scrollp {c[0]:.1f} {c[1]:.1f} {dx} {dy} {phase} cmd'
            s.input(ev(first, 1), *[ev(d, 2) for d in rest], ev((0, 0), 4))
            return s.view() != v, s.state['amplitudeZoomDB'] != a, s.state['waveforms']['main']['zoomAxis']

        tz, az, axis = gesture((12, 3), [(2, 12)] * 4)
        check(8, f'{o}: gesture starting along the time axis zooms only time (later events mostly across)',
              tz and not az and axis == 'time', f'time {tz} amp {az} axis {axis}')
        tz, az, axis = gesture((3, 12), [(12, 2)] * 4)
        check(8, f'{o}: gesture starting across the time axis zooms only amplitude',
              az and not tz and axis == 'amplitude', f'time {tz} amp {az} axis {axis}')
        # Wheel events without phases: each decides.
        res = []
        for along, across in ((10, 3), (3, 10)):
            v, a = reset()
            dx, dy = (along, across) if o == 'horizontal' else (across, along)
            s.input(f'scroll {c[0]:.1f} {c[1]:.1f} {dx} {dy} cmd')
            res.append((s.view() != v, s.state['amplitudeZoomDB'] != a))
        check(8, f'{o}: phase-less events decide per event (mostly along: time only; mostly across: amplitude only)',
              res == [(True, False), (False, True)], str(res))
        s.quit()

n_pass = sum(results)
print(f'\n{n_pass}/{len(results)} checks passed')
sys.exit(0 if n_pass == len(results) else 1)
