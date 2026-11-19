"""Checks milestone 5 acceptance criteria (time markers). Run from prototype/: python3 verify/verify_m5.py

Plays audio (audible). Needs Accessibility and Screen Recording permission for the terminal.
Don't touch the mouse or keyboard while it runs. Screenshots: verify/out/m5/*.png.
Set SKIP_EARLIER=1 to skip criterion 1 (the earlier scripts).
"""
import atexit, math, os, struct, subprocess, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import m3session  # noqa: E402
import m4util  # noqa: E402
from m4util import Session, build_driver, noise, check, P, pb, wait_playhead, wait_until, results, SR  # noqa: E402
from gen_test_audio_m2 import write_float_wav  # noqa: E402

OUT = 'verify/out/m5'
m3session.OUT = m4util.OUT = OUT
AUDIO = f'{OUT}/audio'
NOISE = f'{AUDIO}/noise.wav'
LONG = f'{AUDIO}/silence_12min.wav'


def kill_leftovers():
    subprocess.run(['pkill', '-f', '^build/TranscribeAndPractice[.]app/'], capture_output=True)


kill_leftovers()
atexit.register(kill_leftovers)

# 1. Earlier milestones
if os.environ.get('SKIP_EARLIER'):
    subprocess.run(['./build.sh'], check=True, capture_output=True)
else:
    for script in ['verify_m4.py', 'verify_m4_review.py']:  # verify_m4 runs verify_m3 → m2, m1, builds
        r = subprocess.run([sys.executable, f'verify/{script}'], capture_output=True, text=True)
        fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
        check(1, f'{script} passes', r.returncode == 0 and not fails, '\n'.join(fails) or r.stdout[-400:] + r.stderr[-400:])
    kill_leftovers()

os.makedirs(AUDIO, exist_ok=True)
subprocess.run([sys.executable, 'verify/gen_test_audio_m4.py', AUDIO], check=True, capture_output=True)
if not os.path.exists(LONG):
    write_float_wav(LONG, np.zeros((12 * 60 * 8000, 1), np.float32), 8000)
m4util.X = X = noise()
build_driver()

# --- Reference rules (spec "Time markers") ---
GAP = 30  # minimum space between labels (review change; was 8)
STEPS = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30,
         60, 120, 300, 600, 900, 1800, 3600, 7200]
PARTS = {0.001: 5, 0.002: 4, 0.005: 5, 0.01: 5, 0.02: 4, 0.05: 5, 0.1: 5, 0.2: 4, 0.5: 5, 1: 5, 2: 4, 5: 5,
         10: 5, 15: 3, 30: 6, 60: 5, 120: 4, 300: 5, 600: 5, 900: 3, 1800: 6, 3600: 5, 7200: 4}


def fmt(t, step):
    d = 0 if step >= 1 else math.ceil(-math.log10(step) - 1e-9)
    ms = int(round(t * 1000))
    s = f'{ms // 60000}:{ms // 1000 % 60:02d}'
    return s + ('.' + f'{ms % 1000:03d}'[:d] if d else '')


def ruler_check(s):
    """Criterion 3 properties of the current dump. Returns (ok, detail)."""
    st = s.state
    r, horizontal = st['ruler'], st['orientation'] == 'horizontal'
    L = s.length('navigator')
    rl = r['size']['width'] if horizontal else r['size']['height']
    cross = r['size']['height'] if horizontal else r['size']['width']
    vs, ve = s.view()
    d = st['loaded']['duration']
    lo, hi = max(vs, 0), min(ve, d)
    pps = L / (ve - vs)
    ticks = r['ticks']
    major = sorted((t for t in ticks if t['major']), key=lambda t: t['time'])
    minor = sorted((t for t in ticks if not t['major']), key=lambda t: t['time'])
    if rl != L:
        return False, f'ruler length {rl} != navigator {L}'
    if len(major) < 2:
        return False, f'{len(major)} major ticks'
    step = min(STEPS, key=lambda x: abs(x - (major[1]['time'] - major[0]['time'])))
    want = [k * step for k in range(math.ceil(lo / step - 1e-9), math.floor(hi / step + 1e-9) + 1)]
    if [round(t['time'], 9) for t in major] != [round(t, 9) for t in want]:
        return False, f'step {step}: majors {[t["time"] for t in major][:5]}… want {want[:5]}…'
    for t in ticks:
        if not (lo - 1e-9 <= t['time'] <= hi + 1e-9):
            return False, f'tick outside the file/view: {t["time"]}'
        if abs(t['axis'] - (t['time'] - vs) * pps) > 0.5:
            return False, f'tick {t["time"]} at {t["axis"]}, want {(t["time"] - vs) * pps}'
    if any(t['label'] != fmt(t['time'], step) for t in major):
        return False, f'labels {[t["label"] for t in major][:4]} want {[fmt(t["time"], step) for t in major][:4]}'
    frames = [t['labelFrame'] for t in major if t['labelFrame']]
    ext = lambda f: (f['width'] if horizontal else f['height'])  # noqa: E731
    a0 = lambda f: (f['x'] if horizontal else f['y'])  # noqa: E731
    for t in major:  # a missing label must be one that would leave the strip
        if t['labelFrame'] is None and t['axis'] + 3 + ext(frames[0]) <= rl - 1:
            return False, f'label of {t["time"]} missing'
    for f in frames:
        if f['x'] < 0 or f['y'] < 0 or f['x'] + f['width'] > r['size']['width'] or f['y'] + f['height'] > r['size']['height']:
            return False, f'label frame {f} leaves the strip {r["size"]}'
    for f1, f2 in zip(frames, frames[1:]):
        if a0(f2) - (a0(f1) + ext(f1)) < GAP - 1e-6:
            return False, f'labels {f1} {f2} closer than {GAP} pt'
    # Minimality: the next smaller step would have overlapping labels.
    i = STEPS.index(step)
    if i > 0:
        smaller = STEPS[i - 1]
        f = max(frames, key=ext)
        if horizontal:  # monospaced digits: scale the width by the character count
            w = ext(f) * len(fmt(hi, smaller)) / len(fmt(hi, step))
        else:
            w = ext(f)
        if smaller * pps >= 3 + w + GAP + 1:
            return False, f'step {step} not minimal: {smaller} gives {smaller * pps:.1f} pt for labels {3 + w:.1f} + {GAP}'
    parts = PARTS[step]
    if step / parts * pps >= 4:
        wantm = [m * step / parts for m in range(math.ceil(lo / (step / parts) - 1e-9),
                                                  math.floor(hi / (step / parts) + 1e-9) + 1) if m % parts]
        if [round(t['time'], 9) for t in minor] != [round(t, 9) for t in wantm]:
            return False, f'minor {[t["time"] for t in minor][:6]} want {wantm[:6]} ({parts} parts)'
    elif minor:
        return False, f'minor ticks closer than 4 pt: {step / parts * pps:.2f}'
    if cross < (18 if horizontal else 3 + max(f['width'] for f in frames)):
        return False, f'strip too thin: {cross}'
    return True, f'step {step}, {len(major)} majors, {len(minor)} minors, labels {major[0]["label"]}…'


def read_png(path):
    """RGB array of a PNG (via sips → BMP)."""
    bmp = path[:-4] + '.bmp'
    subprocess.run(['sips', '-s', 'format', 'bmp', path, '--out', bmp], check=True, capture_output=True)
    b = open(bmp, 'rb').read()
    off, w, h, bpp = struct.unpack('<I', b[10:14])[0], *struct.unpack('<ii', b[18:26]), struct.unpack('<H', b[28:30])[0]
    rowlen = (w * bpp // 8 + 3) & ~3
    a = np.frombuffer(b[off:off + rowlen * abs(h)], np.uint8).reshape(abs(h), rowlen)[:, :w * bpp // 8]
    a = a.reshape(abs(h), w, bpp // 8)[:, :, 2::-1]
    return a if h < 0 else a[::-1]


def ruler_point(s, t, cross):
    """Screen point in the ruler at time t, `cross` points from the strip's top / left edge."""
    r = s.state['screenFrames']['ruler']
    vs, ve = s.view()
    f = (t - vs) / (ve - vs)
    if s.state['orientation'] == 'horizontal':
        return r['x'] + f * r['width'], r['y'] + cross
    return r['x'] + cross, r['y'] + f * r['height']


def rp(s, t):
    """Middle of the strip at time t (a point for clicks)."""
    r = s.state['ruler']['size']
    return P(ruler_point(s, t, (r['height'] if s.state['orientation'] == 'horizontal' else r['width']) / 2))


# 2. No file: empty strip
s = Session('c2_empty', [])
check(2, 'no file loaded: the strip exists and has no ticks', s.state['ruler'] is not None and s.state['ruler']['ticks'] == [],
      s.state['ruler'])
s.quit()

for orientation in ['horizontal', 'vertical']:
    o = orientation[0]
    s = Session(f'{o}_layout', [NOISE], orientation)
    s.command('loop off'); s.command('follow off'); s.command('resize 1000,700'); s.command('view 0,10'); s.dump()
    pf = s.state['paneFrames']
    ru, nw, sb, nav = pf['ruler'], pf['navigatorWaveform'], pf['scrollbar'], pf['navigator']
    widest = max(t['labelFrame']['width'] for t in s.state['ruler']['ticks'] if t['labelFrame'])
    if o == 'h':
        ok = (ru['y'] == nav['y'] and ru['height'] == 18 and ru['x'] == nw['x'] and ru['width'] == nw['width']
              and nw['y'] == ru['y'] + 18 and sb['y'] == nw['y'] + nw['height']
              and abs(sb['y'] + sb['height'] - (nav['y'] + nav['height'])) < 1)
    else:
        ok = (ru['x'] == nav['x'] and ru['width'] >= 3 + widest and ru['y'] == nw['y'] and ru['height'] == nw['height']
              and nw['x'] == ru['x'] + ru['width'] and sb['x'] == nw['x'] + nw['width'])
    main = pf['main']
    ok = ok and not (main['x'] <= ru['x'] < main['x'] + main['width'] and main['y'] <= ru['y'] < main['y'] + main['height'])
    s.snapshot('layout')
    check(2, f'{orientation}: strip along the navigator\'s {"top, 18 pt" if o == "h" else "left side"}, waveform '
          f'{"below" if o == "h" else "right of"} it, scrollbar unchanged; not in the main pane (strip {ru})', ok,
          f'ruler {ru} waveform {nw} scrollbar {sb} navigator {nav}')

    # 3. Ticks for several views and two window sizes
    for size in ['1000,700', '700,450']:
        s.command(f'resize {size}')
        for name, view in [('whole', None), ('0-10', (0, 10)), ('1-2', (1, 2)), ('1-1.1', (1, 1.1))]:
            if view:
                s.command(f'view {view[0]},{view[1]}')
            else:
                s.command('view -1,11')
            s.dump()
            ok, detail = ruler_check(s)
            check(3, f'{orientation} {size}: view {s.view()[0]:.3f}–{s.view()[1]:.3f}: {detail}', ok, detail)
        s.snapshot(f'ticks_{size.replace(",", "x")}')
    s.command('resize 1000,700')
    s.command(f'open {os.path.abspath(LONG)}'); s.dump()
    ok, detail = ruler_check(s)
    labels = [t['label'] for t in s.state['ruler']['ticks'] if t['major']]
    check(3, f'{orientation}: 12-minute file, whole view: {detail} ({labels[:3]}…{labels[-1]})',
          ok and '10:00' in labels, detail)
    s.snapshot('long')
    s.command(f'open {os.path.abspath(NOISE)}'); s.command('view 0,10'); s.dump()

    # 4. The ticks follow view changes
    steps = []
    nav_mid = P(s.at('navigator', 0.5))
    s.input(f'scroll {nav_mid} {120 if o == "h" else 0} {0 if o == "h" else 120} cmd')
    steps.append(('zoom', s.view(), ruler_check(s)))
    s.input(f'scroll {nav_mid} 60 0' if o == 'h' else f'scroll {nav_mid} 0 60')
    steps.append(('pan', s.view(), ruler_check(s)))
    s.command('resize 800,500'); s.dump()
    steps.append(('resize', s.view(), ruler_check(s)))
    c, dv = s.state['screenFrames']['content'], s.state['paneFrames']['divider']
    mid = (c['x'] + dv['x'] + dv['width'] / 2, c['y'] + dv['y'] + dv['height'] / 2)
    to = (mid[0], mid[1] + 50) if o == 'h' else (mid[0] + 50, mid[1])
    s.input(f'drag {P(mid)} {P(to)}')
    steps.append(('divider', s.state['navigatorFraction'], ruler_check(s)))
    s.command(f'orientation {"vertical" if o == "h" else "horizontal"}'); s.dump()
    steps.append(('orientation', s.view(), ruler_check(s)))
    s.command(f'orientation {orientation}'); s.command('resize 1000,700')
    s.command('follow on'); s.command('view 0,2'); s.command('playhead 1.0'); s.dump()
    s.input('key space')
    wait_playhead(s, 2.6)
    moved = s.view()
    steps.append(('follow', moved, ruler_check(s)))
    s.input('key space')
    s.command('follow off')
    check(4, f'{orientation}: ticks match the view after zoom, pan, resize, divider drag, orientation switch and '
          'follow during playback', all(r[2][0] for r in steps) and moved[0] > 0,
          [(n, v, r[1]) for n, v, r in steps if not r[0]] or moved)

    # 5. Lines through the strip, no selection band in it (pixel check; review change: was band drawn)
    s.command('view 0,10'); s.command('select 2,3'); s.dump()
    s.command('playhead 4.0'); s.command('select 2,3'); s.dump()  # playhead and last start at 4.0
    s.input('key space')
    wait_playhead(s, 4.6)
    s.input('key space')
    s.dump()
    ph, ls = pb(s)['playhead'], pb(s)['lastStart']
    s.snapshot('lines')
    img = read_png(os.path.abspath(f'{OUT}/{s.name}_lines.png'))
    c = s.state['screenFrames']['content']
    scale = img.shape[1] / c['width']
    top = c['y'] + c['height'] - img.shape[0] / scale  # screen y of the image's top
    rs = s.state['ruler']['size']
    cross = 1.5 if o == 'h' else rs['width'] - 6.5

    def px(t, line=False):
        """Pixel at time t; for a line the reddest within ±1 px along the time axis (the line's
        anti-aliased edge can fall on the rounded pixel)."""
        x, y = ruler_point(s, t, cross)
        r0, c0 = int(round((y - top) * scale)), int(round((x - c['x']) * scale))
        cands = [img[r0 + (d if o == 'v' else 0), c0 + (d if o == 'h' else 0)].astype(int)
                 for d in ((-1, 0, 1) if line else (0,))]
        return max(cands, key=lambda p: p[0] - max(p[1:]))

    ticks = [t['time'] for t in s.state['ruler']['ticks']]
    free = lambda t: all(abs(t - k) > 0.03 for k in ticks)  # noqa: E731
    inside = next(t for t in np.arange(2.05, 3, 0.01) if free(t))
    outside = next(t for t in np.arange(6.05, 7, 0.01) if free(t))
    p_ph, p_ls, p_in, p_out = px(ph, True), px(ls, True), px(inside), px(outside)
    red = p_ph[0] > 150 and p_ph[0] - max(p_ph[1:]) > 80
    desat = p_ls[0] - max(p_ls[1:]) > 15 and p_ls[0] - max(p_ls[1:]) < p_ph[0] - max(p_ph[1:]) - 30
    band = max(p_in) - min(p_in) <= 6 and abs(int(p_in.mean()) - int(p_out.mean())) <= 8  # grey, no accent tint
    check(5, f'{orientation}: inside the strip: playhead line red {list(p_ph)}, last-start line desaturated red '
          f'{list(p_ls)}; no selection band: inside the selection {list(p_in)}, outside {list(p_out)} (both untinted grey)', red and desat and band,
          f'{red} {desat} {band}')

    # 6. Stopped: click and drag in the strip set the playhead, keep the selection
    s.command('select 2,3'); s.dump()
    tol = 10 / s.length('navigator') + 1e-9
    s.input(f'click {rp(s, 5.0)}')
    p = pb(s)
    clicked = (p['playhead'], p['lastStart'], p['clearPoint'], s.sel(), p['playing'])
    s.input(f'down {rp(s, 5.0)}', f'dragto {rp(s, 6.0)}')
    mid_drag = pb(s)['playhead']
    s.input(f'dragto {rp(s, 4.0)}', f'up {rp(s, 4.0)}')
    p = pb(s)
    dragged = (p['playhead'], p['lastStart'], p['clearPoint'], s.sel(), p['playing'])
    s.input('key escape')  # clears the selection: playhead to 2.0
    s.input(f'click {rp(s, 7.0)}')
    s.input('key left')
    rewind = (pb(s)['playing'], pb(s)['lastStart'])
    s.input('key space')
    s.command('view 0,5'); s.command('playhead 3.0'); s.dump()
    r = s.state['screenFrames']['ruler']
    beyond = P((r['x'] + r['width'] + 40, r['y'] + 9) if o == 'h' else (r['x'] + r['width'] / 2, r['y'] + r['height'] + 40))
    s.input(f'drag {rp(s, 2.0)} {beyond}')
    at_end = pb(s)['playhead']
    near = lambda a, b: abs(a - b) <= tol  # noqa: E731
    check(6, f'{orientation}: stopped: click at 5.0 → playhead, last start, clear point at 5.0; drag 5 → 6 → 4: '
          'playhead ~6 mid-drag, 4.0 at the end; selection 2–3 kept; no playback',
          all(near(x, 5.0) for x in clicked[:3]) and clicked[3] == (2, 3) and not clicked[4]
          and near(mid_drag, 6.0) and all(near(x, 4.0) for x in dragged[:3]) and dragged[3] == (2, 3) and not dragged[4],
          f'{clicked} mid {mid_drag} {dragged}')
    check(6, f'{orientation}: no selection: after a strip click at 7.0, ← plays from 7.0; a drag past the view end '
          f'stops at the view end (5.0): {at_end}',
          rewind[0] and near(rewind[1], 7.0) and abs(at_end - 5.0) < 1e-9, f'{rewind} {at_end}')

    # 7. Playing: a press jumps playback, the rest of the drag does nothing
    s.command('view 0,10'); s.command('playhead 1.0'); s.dump()
    s.input('key space')
    wait_playhead(s, 1.3)
    rec = m4util.Recording(s, f'{o}_c7')
    s.input(f'down {rp(s, 6.0)}')
    p = pb(s)
    pressed = (p['playing'], p['lastStart'], s.sel())
    s.input(f'dragto {rp(s, 7.0)}')
    p = pb(s)
    moved = (p['playing'], p['lastStart'], p['playhead'])
    s.input(f'up {rp(s, 7.0)}')
    time.sleep(0.3)
    s.input('key space')
    audio = rec.stop()
    # The recording: a run of file samples from ~1.3 s, then the file from the press point on.
    a0 = next((i for i in range(int(1.2 * SR), int(3 * SR)) if np.array_equal(audio[0], X[i])), None)
    j = 0
    while a0 is not None and j < len(audio) and np.array_equal(audio[j], X[a0 + j]):
        j += 1
    jump = int(round(pressed[1] * SR))
    rest = audio[j:]
    seek_ok = a0 is not None and len(rest) > 0.2 * SR and np.array_equal(rest, X[jump:jump + len(rest)])
    s.command('loop on'); s.command('playhead 5.0'); s.command('select 2,3'); s.dump()
    s.input('key space')
    time.sleep(0.2)
    s.input(f'click {rp(s, 2.2)}')
    trace = []
    for _ in range(25):
        s.dump(); trace.append((pb(s)['playing'], pb(s)['playhead'])); time.sleep(0.06)
    s.input('key space')
    s.command('loop off'); s.command('select')
    loops = all(pl and 2.0 <= t < 3.0 for pl, t in trace) and any(b[1] < a[1] for a, b in zip(trace, trace[1:]))
    check(7, f'{orientation}: playing from 1.0, press at 6.0: playing goes on, last start {pressed[1]:.3f}, selection '
          'unchanged; rendered audio jumps to the file samples from there (sample-exact); dragging to 7.0 changes nothing',
          pressed[0] and near(pressed[1], 6.0) and pressed[2] is None and moved[0] and moved[1] == pressed[1]
          and seek_ok, f'{pressed} {moved} start {a0} run {j} seek {seek_ok}')
    check(7, f'{orientation}: loop on, selection 2–3, playing from 5.0: a strip click at 2.2 → playback loops in 2–3',
          loops, trace[::5])

    # 8. The last-start line in the strip; selection edges aren't grabbed
    s.command('playhead 3.0'); s.dump()
    s.input('key space')
    wait_playhead(s, 3.5)
    s.input('key space')
    s.dump()
    ph0 = pb(s)['playhead']
    s.input(f'move {rp(s, 3.0)}')
    cursor = s.state['ruler']['cursor']
    s.input(f'drag {rp(s, 3.0)} {rp(s, 1.0)}')
    p = pb(s)
    stopped = (p['lastStart'], p['playhead'], p['playing'], s.sel())
    s.input('key space')
    wait_playhead(s, ph0 + 0.2)
    before = pb(s)['playhead']
    s.input(f'drag {rp(s, pb(s)["lastStart"])} {rp(s, 0.5)}')  # playback started at ph0: the line is there
    p = pb(s)
    playing = (p['lastStart'], p['playing'], p['playhead'] > before, s.sel())
    s.input('key space')
    s.command('select 2,3'); s.dump()
    s.input(f'click {rp(s, 2.0)}')
    edge = (s.sel(), pb(s)['playhead'])
    s.input(f'drag {rp(s, 3.0)} {rp(s, 3.5)}')
    edge2 = (s.sel(), pb(s)['playhead'])
    want_cursor = 'columnResize' if o == 'h' else 'rowResize'
    check(8, f'{orientation}: hovering the last-start line shows {want_cursor}; dragged 3 → 1 (stopped) and from the playback start → 0.5 '
          'during playback, alone; playback unaffected',
          cursor == want_cursor and near(stopped[0], 1.0) and stopped[1] == ph0 and not stopped[2] and stopped[3] is None
          and near(playing[0], 0.5) and playing[1] and playing[2] and playing[3] is None,
          f'{cursor} {stopped} (playhead was {ph0}) {playing}')
    check(8, f'{orientation}: a press on the selection start (2.0) in the strip sets the playhead; a drag from the end '
          'edge (3.0 → 3.5) moves the playhead; the selection stays 2–3',
          edge[0] == (2, 3) and near(edge[1], 2.0) and edge2[0] == (2, 3) and near(edge2[1], 3.5), f'{edge} {edge2}')
    s.command('select'); s.command('resize 1000,700')
    s.quit()

print(f'\n{sum(results)}/{len(results)} checks passed')
sys.exit(0 if all(results) else 1)
