"""Checks milestone 8 acceptance criteria (spectrogram). Run from prototype/:
python3 verify/verify_m8.py

Needs Accessibility and Screen Recording permission for the terminal. Don't touch the mouse or
keyboard while it runs (it also plays audio briefly). Screenshots: verify/out/m8/*.png.
Only milestone 8 is checked (earlier milestones are not re-verified).
"""
import atexit, base64, json, math, os, struct, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, check, P, results, DOMAIN  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m8'
m3session.OUT = m4util.OUT = OUT
m3session.DRIVER = f'{OUT}/inputdriver'
AUDIO = os.path.abspath(f'{OUT}/audio')
TONES = f'{AUDIO}/tones.wav'
HI96 = f'{AUDIO}/hi96.wav'
SR = 44100
KEYS = ['mainPaneMode', 'spectrogramWindowMs', 'spectrogramRetina']
ONLY = set(os.environ.get('ONLY', '').split(',')) - {''}


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

# --- Test audio: separate tones (peak amplitude 10^(dB/20)), a chord, silence between ---
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
t96 = np.arange(2 * 96000) / 96000
write_float_wav(HI96, (0.5 * np.sin(2 * np.pi * 1000 * t96)).astype(np.float32).reshape(-1, 1), 96000)
X64 = X.astype(np.float64)

# 1. Builds
r = subprocess.run(['./build.sh'], capture_output=True, text=True)
check(1, 'builds', r.returncode == 0 and 'error' not in r.stdout + r.stderr, r.stdout[-400:] + r.stderr[-400:])
build_driver()
reset_defaults()


# --- Helpers ---
def sp(s):
    return s.state['spectrogram']


def wait_idle(s, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        s.dump()
        if sp(s)['mode'] != 'spectrogram' or (not sp(s)['busy'] and sp(s)['complete']):
            return True
        time.sleep(0.1)
    return False


def specdump(s, tag):
    path = os.path.abspath(f'{OUT}/{s.name}_{tag}_spec.json')
    s.command(f'specdump {path}')
    d = json.load(open(path))
    lv = np.frombuffer(base64.b64decode(d['levelsFloat32LE']), '<f4').reshape(d['columns'], d['rows'])
    return d, lv


def gauss(n):
    k = np.arange(n) - (n - 1) / 2
    return np.exp(-0.5 * (2.5 * k / ((n - 1) / 2)) ** 2)


def reference(d, x=X64):
    n = d['windowLength']
    fs = d['sampleRate']
    w = gauss(n)
    h = (n - 1) // 2
    freqs = np.array([np.nan if f is None else f for f in d['frequencies']])
    valid = ~np.isnan(freqs)
    b = freqs[valid] * 65536 / fs
    i0 = np.floor(b).astype(int)
    t = b - i0
    ref = np.full((d['columns'], d['rows']), np.nan)
    xp = np.concatenate([np.zeros(h), x, np.zeros(h + 1)])
    cols = [(i, c) for i, c in enumerate(d['centreSamples']) if c is not None]
    for j in range(0, len(cols), 64):
        part = cols[j:j + 64]
        seg = np.stack([xp[c:c + n] * w for _, c in part])
        mag = np.abs(np.fft.rfft(seg, 65536, axis=1))
        m = mag[:, i0] * (1 - t) + mag[:, i0 + 1] * t
        lev = 20 * np.log10(np.maximum(m * 2 / w.sum(), 1e-30))
        for (i, _), row in zip(part, lev):
            ref[i, valid] = row
    return ref


def compare(d, lv):
    ref = reference(d)
    mask = ref > -100
    nan_ok = bool(np.all(np.isnan(lv[np.isnan(ref)])))
    diff = float(np.max(np.abs(ref[mask] - lv[mask]))) if mask.any() else 0.0
    return diff, nan_ok, ref


def semitone(f):
    return 12 * math.log2(f / 440) + 69 - 20.5


def window_n(ms, fs=SR):
    n = 2.5 * ms / 1000 * fs + 1
    return min(2 * round((n - 1) / 2) + 1, 65535)


def to_screen(s, name):
    """A SwiftUI-reported frame (window coordinates) in screen coordinates."""
    pf, sf = s.state['paneFrames'], s.state['screenFrames']
    dx, dy = sf['main']['x'] - pf['main']['x'], sf['main']['y'] - pf['main']['y']
    r = pf[name]
    return {'x': r['x'] + dx, 'y': r['y'] + dy, 'width': r['width'], 'height': r['height']}


def read_snapshot(path):
    """PNG → RGB array via sips (BMP)."""
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
    return a[:, :, 2::-1].astype(int) if bpp >= 3 else a


class Shot:
    def __init__(self, s, tag):
        s.snapshot(tag)
        self.img = read_snapshot(os.path.abspath(f'{OUT}/{s.name}_{tag}.png'))
        self.win = s.state['screenFrames']['window']
        self.scale = self.img.shape[1] / self.win['width']

    def px(self, x, y):
        """RGB at a screen point."""
        i = int((y - self.win['y']) * self.scale)
        j = int((x - self.win['x']) * self.scale)
        return self.img[min(max(i, 0), self.img.shape[0] - 1), min(max(j, 0), self.img.shape[1] - 1)]


def view_px(s):
    v = s.state['view']
    return v['start'], sp(s)['pixelSeconds']


def whole(delta, px):
    k = delta / px
    return abs(k - round(k)) < 1e-6 * max(1, abs(k)), k


def has_screen(s, retina):
    return any((sc['scale'] > 1) == retina for sc in sp(s)['screens'])


def place(s, where):
    s.command(f'screen {where}')
    time.sleep(0.3)
    s.dump()


def session(name, orientation='horizontal', opens=(TONES,), where='plain', size=(1000, 700)):
    s = Session(name, opens=opens, orientation=orientation)
    if where:
        place(s, where)
    if size:
        s.command(f'resize {size[0]},{size[1]}')
    s.bring_to_front()
    s.dump()
    return s


# 2. Controls
if run(2):
    s = session('c2_nofile', opens=())
    check(2, 'no controls with no file', 'modePicker' not in s.state['paneFrames'], str(list(s.state['paneFrames'])))
    s.snapshot('nofile')
    s.quit()
    for o in ('horizontal', 'vertical'):
        s = session(f'c2_{o}', orientation=o)
        g = sp(s)
        check(2, f'{o}: defaults waveform, 50 ms, Retina off',
              (g['mode'], g['windowLengthMs'], g['retina']) == ('waveform', 50, False), str(g))
        pf = s.state['paneFrames']
        m, mp = pf['main'], pf.get('modePicker')
        ok = mp is not None and abs((m['x'] + m['width']) - (mp['x'] + mp['width'])) < 30 and abs(mp['y'] - m['y']) < 30
        check(2, f'{o}: dropdown in the main pane\'s top-right corner', ok, f'main {m} picker {mp}')
        check(2, f'{o}: waveform mode shows no slider, Retina toggle or progress indicator',
              not any(k in pf for k in ('windowSlider', 'retinaToggle', 'progress')), str(list(pf)))
        s.snapshot('waveform')
        s.command('mode spectrogram')
        wait_idle(s)
        pf = s.state['paneFrames']
        present = all(k in pf for k in ('windowSlider', 'windowReadout', 'retinaToggle', 'progress'))
        left = present and all(pf[k]['x'] + pf[k]['width'] <= pf['modePicker']['x'] + 1
                               for k in ('windowSlider', 'retinaToggle', 'progress'))
        order = present and pf['retinaToggle']['x'] < pf['windowSlider']['x'] < pf['progress']['x'] < pf['modePicker']['x']
        check(2, f'{o}: spectrogram mode shows Retina, slider with readout, progress (right to left: dropdown, '
                 'progress, slider, Retina)', present and left and order, str({k: pf.get(k) for k in pf}))
        s.snapshot('spectrogram')
        if o == 'horizontal':
            sl = to_screen(s, 'windowSlider')
            y = sl['y'] + sl['height'] / 2
            knob = sl['x'] + 10 + (math.log(50 / 10) / math.log(50)) * (sl['width'] - 20)
            s.input(f'drag {knob:.1f} {y:.1f} {sl["x"] - 200:.1f} {y:.1f}')
            lo = sp(s)['windowLengthMs']
            s.input(f'drag {sl["x"] + 10:.1f} {y:.1f} {sl["x"] + sl["width"] + 200:.1f} {y:.1f}')
            hi = sp(s)['windowLengthMs']
            s.input(f'click {sl["x"] + sl["width"] / 2:.1f} {y:.1f}')
            mid = sp(s)['windowLengthMs']
            check(2, 'slider ends 10 and 500 ms, middle about 70.7 ms (logarithmic)',
                  abs(lo - 10) < 1e-9 and abs(hi - 500) < 1e-9 and abs(mid / 70.71 - 1) < 0.03, f'{lo} {hi} {mid}')
            s.command('window 120')
            s.command('retina on')
            s.dump()
            s.quit()
            s = session('c2_relaunch')
            g = sp(s)
            check(2, 'mode, window length and Retina restored after a relaunch',
                  (g['mode'], round(g['windowLengthMs'], 6), g['retina']) == ('spectrogram', 120, True), str(g))
            s.quit()
            reset_defaults()
        else:
            s.quit()

# 3. Levels against the numpy reference; 4. window length
if run(3) or run(4):
    # Vertical on the plain screen, wide window: the whole frequency range is visible.
    s = session('c3_full', orientation='vertical', size=(2000, 700))
    s.command('mode spectrogram')
    for ms in (10, 50, 500):
        s.command(f'window {ms}')
        idle = wait_idle(s)
        d, lv = specdump(s, f'w{ms}')
        diff, nan_ok, ref = compare(d, lv)
        check(3, f'vertical, Retina off, {ms} ms: levels match the reference within 0.01 dB (above −100 dB)',
              idle and d['complete'] and diff <= 0.01 and nan_ok, f'max diff {diff:.5f} nan_ok {nan_ok} idle {idle}')
        check(4, f'{ms} ms at 44.1 kHz: N = {window_n(ms)}',
              d['windowLength'] == window_n(ms) and sp(s)['windowSamples'] == window_n(ms), str(d['windowLength']))
        # Tone peaks: the note's row (±1), and its level where the peak is wider than a row.
        rps = sp(s)['freqView']['rowsPerSemitone']
        cs = np.array([np.nan if c is None else c for c in d['centreSamples']])
        sigma_f = 1 / (2 * math.pi * ms / 2000)
        for a, b, f, db, name in TONE_LIST:
            i = int(np.nanargmin(np.abs(cs - (a + b) / 2 * SR)))
            q = int(np.nanargmax(lv[i]))
            qexp = math.floor(semitone(f) * rps) - d['firstRow']
            offset = f * (2 ** (0.5 / rps / 12) - 1)  # the note sits on a row boundary
            loss = 8.686 * 0.5 * (offset / sigma_f) ** 2
            row_ok = abs(q - qexp) <= 1
            if loss < 0.3:
                check(3, f'{ms} ms: {name} peak at its row and {db:g} dB within 0.5 dB',
                      row_ok and abs(lv[i, q] - db) <= 0.5, f'row {q} vs {qexp}, level {lv[i, q]:.2f}')
            else:
                check(3, f'{ms} ms: {name} peak at its row (peak narrower than a row: level not compared, '
                         f'{loss:.1f} dB expected loss)', row_ok, f'row {q} vs {qexp}')
        # Columns: pixel centres; nothing in the margins.
        v0, px = d['origin'] + d['firstColumn'] * d['secondsPerPixel'], d['secondsPerPixel']
        exp_c = [math.floor((v0 + (i + 0.5) * px) * SR + 0.5) for i in range(d['columns'])]
        cen_ok = all(c is None or c == e for c, e in zip(d['centreSamples'], exp_c))
        margin_ok = all((c is None) == (e < 0 or e >= len(X)) for c, e in zip(d['centreSamples'], exp_c))
        blank_ok = all(np.all(np.isnan(lv[i])) for i, c in enumerate(d['centreSamples']) if c is None)
        nblank = sum(c is None for c in d['centreSamples'])
        check(3, f'{ms} ms: columns at the pixel-centre samples; margins blank',
              cen_ok and margin_ok and blank_ok and nblank > 0, f'cen {cen_ok} margin {margin_ok} blank {blank_ok} n {nblank}')
    s.snapshot('full_vertical')
    s.quit()
    # Horizontal, Retina on (on a Retina screen if there is one) and off.
    s = session('c3_retina', where='retina')
    s.command('mode spectrogram')
    scale = sp(s)['backingScale']
    for retina, wins in (('on', (10, 50, 500)), ('off', (50,))):
        s.command(f'retina {retina}')
        for ms in wins:
            s.command(f'window {ms}')
            idle = wait_idle(s)
            d, lv = specdump(s, f'r{retina}_w{ms}')
            diff, nan_ok, _ = compare(d, lv)
            ps = sp(s)['pixelScale']
            dims = d['columns'] == sp(s)['timePixels'] and d['rows'] == round(s.state['waveforms']['main']['size']['height'] * ps)
            check(3, f'horizontal, Retina {retina} (scale {ps:g}), {ms} ms: levels match the reference within 0.01 dB; '
                     'one column/row per pixel', idle and diff <= 0.01 and nan_ok and dims,
                  f'diff {diff:.5f} nan {nan_ok} dims {d["columns"]}x{d["rows"]}')
    s.snapshot('retina')
    s.quit()
    if run(4):
        s = session('c4_96k', opens=(HI96,))
        s.command('mode spectrogram')
        s.command('window 500')
        wait_idle(s)
        d, lv = specdump(s, 'w500')
        check(4, '96 kHz at 500 ms: N = 65,535 (cut to the FFT)',
              sp(s)['windowSamples'] == 65535 and d['windowLength'] == 65535, str(d['windowLength']))
        s.command('window 50')
        wait_idle(s)
        d, lv = specdump(s, 'w50')
        x96 = (0.5 * np.sin(2 * np.pi * 1000 * t96))
        ref = reference(d, x96)
        mask = ref > -100
        diff = float(np.max(np.abs(ref[mask] - lv[mask])))
        check(4, f'96 kHz at 50 ms: N = {window_n(50, 96000)}, levels match', d['windowLength'] == window_n(50, 96000)
              and diff <= 0.01, f'{d["windowLength"]} diff {diff}')
        s.quit()


def fv(s):
    return sp(s)['freqView']


# 5. Frequency axis
if run(5):
    for o in ('horizontal', 'vertical'):
        s = session(f'c5_{o}', orientation=o)
        s.command('mode spectrogram')
        wait_idle(s)
        f = fv(s)
        rps = f['rowsPerSemitone']
        check(5, f'{o}: 14 points per semitone; initial view centred on C4',
              f['pointsPerSemitone'] == 14 and rps == 14 * sp(s)['pixelScale']
              and abs((f['low'] + f['high']) / 2 - 39.5) <= 1 / rps + 1e-9, str(f))
        # Direction: A4 (3–5 s) is brightest where its semitone is.
        main = s.state['screenFrames']['main']
        sh = Shot(s, 'direction')
        pos = semitone(440) - f['low']
        if o == 'horizontal':
            x = main['x'] + (4.0 - s.view()[0]) / (s.view()[1] - s.view()[0]) * main['width']
            ys = np.arange(main['y'] + 45, main['y'] + main['height'] - 2, 0.5)
            br = [sum(sh.px(x, y)) for y in ys]
            got, exp = ys[int(np.argmax(br))], main['y'] + main['height'] - pos * 14
        else:
            y = main['y'] + (4.0 - s.view()[0]) / (s.view()[1] - s.view()[0]) * main['height']
            xs = np.arange(main['x'] + 2, main['x'] + main['width'] - 2, 0.5)
            br = [sum(sh.px(x, y)) for x in xs]
            got, exp = xs[int(np.argmax(br))], main['x'] + pos * 14
        check(5, f'{o}: low notes at the {"bottom" if o == "horizontal" else "left"} (A4 drawn at its position)',
              abs(got - exp) <= 3, f'brightest at {got:.1f}, expected {exp:.1f}')
        # Option-drag / middle drag across the time axis.
        c = s.at('main', 0.5)
        sign = -1 if o == 'horizontal' else 1  # toward higher frequencies on screen
        low0, view0 = fv(s)['low'], s.view()
        if o == 'horizontal':
            s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0]:.1f} {c[1] - 140:.1f} option')
        else:
            s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0] + 140:.1f} {c[1]:.1f} option')
        low1 = fv(s)['low']
        check(5, f'{o}: Option-drag 140 pt toward high notes moves the view 10 semitones lower (grab); time unchanged',
              abs((low1 - low0) + 10) <= 1 / rps + 1e-9 and s.view() == view0, f'{low0} → {low1}, view {s.view()}')
        if o == 'horizontal':
            s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0]:.1f} {c[1] + 70:.1f} - middle')
        else:
            s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0] - 70:.1f} {c[1]:.1f} - middle')
        low2 = fv(s)['low']
        check(5, f'{o}: middle drag 70 pt the other way: 5 semitones higher', abs((low2 - low1) - 5) <= 1 / rps + 1e-9,
              f'{low1} → {low2}')
        for k in range(6):
            if o == 'horizontal':
                s.input(f'drag {c[0]:.1f} {main["y"] + 20:.1f} {c[0]:.1f} {main["y"] + main["height"] - 20:.1f} option')
            else:
                s.input(f'drag {main["x"] + main["width"] - 20:.1f} {c[1]:.1f} {main["x"] + 20:.1f} {c[1]:.1f} option')
        high = fv(s)['high']
        for k in range(6):
            if o == 'horizontal':
                s.input(f'drag {c[0]:.1f} {main["y"] + main["height"] - 20:.1f} {c[0]:.1f} {main["y"] + 20:.1f} option')
            else:
                s.input(f'drag {main["x"] + 20:.1f} {c[1]:.1f} {main["x"] + main["width"] - 20:.1f} {c[1]:.1f} option')
        low = fv(s)['low']
        check(5, f'{o}: panning stops at C9 + ½ and A0 − ½ (within a pixel)',
              abs(high - 100) <= 1 / rps + 1e-9 and abs(low) <= 1 / rps + 1e-9, f'high {high} low {low}')
        s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0] + (0 if o == "horizontal" else 100):.1f} '
                f'{c[1] + (-100 if o == "horizontal" else 0):.1f} option')
        kept = fv(s)['low']
        s.command('mode waveform')
        s.command('mode spectrogram')
        a = fv(s)['low'] if s.dump() else None
        s.command(f'open {TONES}')
        b = fv(s)['low'] if s.dump() else None
        check(5, f'{o}: frequency view kept across a mode switch and opening a file', a == kept and b == kept,
              f'{kept} {a} {b}')
        if o == 'vertical':
            s.command('resize 2000,700')
            s.dump()
            f = fv(s)
            span = s.state['waveforms']['main']['size']['width'] / 14
            check(5, 'pane larger than the range: the range is centred',
                  span > 100 and abs(f['low'] - (100 - span) / 2) <= 1 / rps + 1e-9, f'{f} span {span}')
            wait_idle(s)
            s.snapshot('centred')
        s.quit()


# 6. Whole-pixel panning
def pan_checks(s, label, scale):
    s.command('view 2,6')
    s.dump()
    c = s.at('main', 0.5)
    hor = s.state['orientation'] == 'horizontal'

    def along(p, d):
        return (p[0] + d, p[1]) if hor else (p[0], p[1] + d)

    def sc_(d):  # a scroll along the time axis
        return f'{d} 0' if hor else f'0 {d}'

    def step(desc, *lines, expect_move=True):
        a, px = view_px(s)
        s.input(*lines)
        b, px2 = view_px(s)
        w, k = whole(b - a, px)
        ok = w and (abs(k) >= 0.5 if expect_move else True)
        check(6, f'{label}: {desc} moves by whole pixels', ok, f'{k:.6f} pixels')
        return k

    half = 0.5 / scale
    k1 = step(f'a {half:g}-point scroll (half a pixel)', f'scrollf {P(c)} {sc_(half)}', expect_move=False)
    k2 = step(f'a second {half:g}-point scroll', f'scrollf {P(c)} {sc_(half)}')
    check(6, f'{label}: two half-pixel scrolls move one pixel in total', round(k1) == 0 and abs(round(k2)) == 1,
          f'{k1} {k2}')
    step('a 3.3-pixel scroll', f'scrollf {P(c)} {sc_(3.3 / scale)}')
    step('an Option-drag of 37.3 points', f'drag {P(c)} {P(along(c, 37.3))} option')
    step('a middle drag of 21.7 points', f'drag {P(c)} {P(along(c, -21.7))} - middle')
    sc = s.state['screenFrames']['scrollbar']
    kr = s.state['scrollbar']['knobRect']
    k = (sc['x'] + kr['x'] + kr['width'] / 2, sc['y'] + kr['y'] + kr['height'] / 2)
    step('a scrollbar knob drag of 13.7 points', f'drag {P(k)} {P(along(k, 13.7))}')
    s.dump()
    kr = s.state['scrollbar']['knobRect']
    if hor:
        t = (sc['x'] + min(kr['x'] + kr['width'] + 40, sc['width'] - 30), k[1])
    else:
        t = (k[0], sc['y'] + min(kr['y'] + kr['height'] + 40, sc['height'] - 30))
    step('a scrollbar track click', f'click {P(t)}')
    s.input(f'scroll {P(c)} {sc_(30000)}')
    check(6, f'{label}: at the limit the view stops exactly at −50 ms', abs(view_px(s)[0] + 0.05) < 1e-12,
          str(view_px(s)))


def follow_check(s, label):
    s.command('view 0,6')
    s.command('playhead 2.5')
    s.command('follow on')
    s.dump()
    s.input('key space')
    starts = []
    end = time.time() + 3
    while time.time() < end:
        s.dump()
        starts.append(view_px(s))
        time.sleep(0.05)
    s.input('key space')
    s.command('follow off')
    moves = [(b[0] - a[0], a[1]) for a, b in zip(starts, starts[1:]) if b[0] != a[0]]
    bad = [d / p for d, p in moves if not whole(d, p)[0]]
    check(6, f'{label}: follow during playback moves the view by whole pixels', len(moves) >= 5 and not bad,
          f'{len(moves)} moves, bad {bad[:5]}')


if run(6):
    for mode in ('waveform', 'spectrogram'):
        for o in ('horizontal', 'vertical'):
            s = session(f'c6_{mode}_{o}', orientation=o)
            s.command(f'mode {mode}')
            wait_idle(s)
            pan_checks(s, f'{mode}, {o}', 1)
            if o == 'horizontal':
                follow_check(s, f'{mode}, {o}')
            s.quit()
    s = session('c6_retina', where='retina')
    if has_screen(s, True):
        s.command('mode spectrogram')
        s.command('retina on')
        wait_idle(s)
        sc = sp(s)['pixelScale']
        check(6, f'Retina on a Retina screen: pixels are physical (scale {sc:g})', sc > 1, str(sc))
        pan_checks(s, 'spectrogram, Retina', sc)
    else:
        check(6, 'Retina screen available for the physical-pixel pan checks', False, 'no Retina screen')
    s.quit()

# 7. Cache
if run(7):
    s = session('c7')
    s.command('mode spectrogram')
    s.command('view 1,7')
    wait_idle(s)
    c = s.at('main', 0.5)
    n0 = sp(s)['computedColumns']
    a, px = view_px(s)
    s.input(f'scroll {P(c)} -7 0')
    wait_idle(s)
    b, _ = view_px(s)
    k = abs(round((b - a) / px))
    n1 = sp(s)['computedColumns']
    check(7, f'a pan by {k} pixels computes exactly {k} columns', k == 7 and n1 - n0 == k, f'{n1 - n0} computed, moved {k}')
    s.input(f'drag {c[0]:.1f} {c[1]:.1f} {c[0]:.1f} {c[1] - 50:.1f} option')
    s.command('amplitude 12')
    wait_idle(s)
    n2 = sp(s)['computedColumns']
    check(7, 'a frequency pan and an amplitude zoom compute no columns', n2 == n1, f'{n2 - n1}')
    s.command('amplitude 0')
    d, _ = specdump(s, 'before_window')
    visible = sum(c is not None for c in d['centreSamples'])
    s.command('window 80')
    wait_idle(s)
    n3 = sp(s)['computedColumns']
    check(7, 'a window length change recomputes all visible columns', n3 - n2 == visible, f'{n3 - n2} vs {visible}')
    # Busy: slowed down so it can be observed.
    s.command('window 500')
    wait_idle(s)
    s.command('specdelay 400')
    stale0 = sp(s)['staleDraws']
    s.input(f'scroll {P(c)} 120 0 cmd')
    g = sp(s)
    sh = Shot(s, 'busy')
    pf = s.state['paneFrames']
    check(7, 'while busy: busy flag set, progress indicator shown, previous image stretched',
          g['busy'] and 'progress' in pf and g['staleShown'] and g['staleDraws'] > stale0, str(g))
    prog = to_screen(s, 'progress')
    pix = [sh.px(prog['x'] + prog['width'] * fx, prog['y'] + prog['height'] * fy) for fx in (0.3, 0.5, 0.7) for fy in (0.3, 0.5, 0.7)]
    check(7, 'progress indicator visible in the screenshot (not a uniform patch)',
          max(int(np.ptp([sum(p) for p in pix])), 0) > 30, str([list(p) for p in pix]))
    s.command('specdelay 0')
    idle = wait_idle(s)
    d, lv = specdump(s, 'after_zoom')
    diff, nan_ok, _ = compare(d, lv)
    check(7, 'afterwards the image matches the reference', idle and not sp(s)['busy'] and diff <= 0.01 and nan_ok,
          f'diff {diff} idle {idle}')
    s.snapshot('after_zoom')
    s.quit()

# 8. Behaviour in spectrogram mode
if run(8):
    for o in ('horizontal', 'vertical'):
        s = session(f'c8_{o}', orientation=o)
        s.command('mode spectrogram')
        s.command('view 2,8')
        wait_idle(s)
        L = s.length('main')
        t = lambda fr: 2 + fr * 6  # noqa: E731
        s.input(f'drag {P(s.at("main", 0.1, 0.6))} {P(s.at("main", 0.15, 0.6))}')
        sel = s.sel()
        check(8, f'{o}: a drag selects', sel is not None and abs(sel[0] - t(0.1)) < 0.02 and abs(sel[1] - t(0.15)) < 0.02,
              str(sel))
        s.input(f'move {P(s.at("main", 0.4, 0.6))}')
        pa = s.state['ruler']['pointerAxis']
        check(8, f'{o}: the strip\'s pointer line follows the pointer over the spectrogram',
              pa is not None and abs(pa - 0.4 * s.length('navigator')) < 2, str(pa))
        sh = Shot(s, 'overlays')
        inside = sh.px(*s.at('main', 0.125, 0.9))
        outside = sh.px(*s.at('main', 0.3, 0.9))
        check(8, f'{o}: the selection band is drawn over the spectrogram', abs(int(sum(inside)) - int(sum(outside))) > 20
              and inside.tolist() != outside.tolist(), f'inside {inside} outside {outside}')
        s.input(f'click {P(s.at("main", 0.6, 0.6))}')
        p = s.state['playback']
        check(8, f'{o}: a click seeks (clears the selection)', s.sel() is None and abs(p['playhead'] - t(0.6)) < 0.02,
              str(p['playhead']))
        sh = Shot(s, 'playhead')
        ax = s.state['waveforms']['main']['playheadAxis']
        main = s.state['screenFrames']['main']
        pt = (main['x'] + ax, main['y'] + main['height'] * 0.9) if o == 'horizontal' else (main['x'] + main['width'] * 0.9, main['y'] + ax)
        red = sh.px(*pt)
        check(8, f'{o}: the playhead line is drawn over the spectrogram', red[0] > 150 and red[0] > red[1] + 60, str(red))
        s.input(f'move {P(s.at("main", 0.8, 0.6))}', 'key b')
        if s.state['timeSignatureDialog']['shown']:
            s.command('tsdialog dontset')
        s.dump()
        bt = [b['sample'] / 44100 for b in s.state['beats']]
        check(8, f'{o}: B places a beat at the pointer', len(bt) == 1 and abs(bt[0] - t(0.8)) < 0.02, str(bt))
        d0, lv0 = specdump(s, 'gain0')
        c = s.at('main', 0.5)
        s.input(f'scroll {P(c)} 0 100 cmd' if o == 'horizontal' else f'scroll {P(c)} 100 0 cmd')
        wait_idle(s)
        g = s.state['amplitudeZoomDB']
        d1, lv1 = specdump(s, 'gain1')
        same = np.array_equal(np.nan_to_num(lv0, nan=-999), np.nan_to_num(lv1, nan=-999))
        check(8, f'{o}: ⌘ + scroll across adds its dB at rendering ({g:.2f} dB; stored levels unchanged)',
              g > 5 and abs(sp(s)['renderedGainDB'] - g) < 1e-9 and same, f'{g} {sp(s)["renderedGainDB"]} same {same}')
        s.snapshot('gain')
        s.quit()

reset_defaults()
print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
